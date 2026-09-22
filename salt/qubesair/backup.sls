{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

qubesair.backup — snapshot the console database, encrypt it off-host, prune.

Why this is a state of its own: it is the one thing that has to keep working when
the console does not. console.sls deploys a service; this deploys the record that
the service can be rebuilt from.

Deploy (from dom0), after qubesair.console has run at least once:

  sudo qubesctl --skip-dom0 --targets=<cfg.qubesair.qube> state.apply qubesair.backup

What this state deliberately does NOT do
----------------------------------------
It never writes the passphrase. The archives are only openable with the key in
<data_dir>/backup.env, so a state that owned that file would hold the key to every
backup in a salt-managed file — and, worse, would REPLACE it on the next apply
whenever someone edited it, silently orphaning every archive written under the
previous one. This state only proves the file exists and is non-empty, and fails
the run with the one-time command if it is not.

It also does not mount the off-host medium. What that is (a LUKS volume, a USB
disk attached with qvm-block, a network mount) is a deployment decision this
state cannot make for you; the unit declares RequiresMountsFor so that a missing
mount fails the backup loudly instead of quietly leaving the only copy on the
machine that just lost its disk.

Why the timer is not the whole story
------------------------------------
A timer cannot fire while the AppVM is down, and Persistent=true does not rescue
that here: the stamp it uses to notice a missed run lives under
/var/lib/systemd/timers/, which is on the root volume and is discarded on every
reboot of this AppVM. So catch-up cannot span a restart, and a console qube that
is usually off at 03:30 would report a healthy timer while never backing up. Hence
the rc.local block below: one backup per boot, in addition to the schedule. The
cost is one extra archive per boot, bounded by the same keep window.
#}

{%- from 'config.jinja' import cfg with context -%}

{%- set qa = cfg.get('qubesair', {}) -%}
{%- set bk = qa.get('backup', {}) -%}

{%- set svc_user = qa.get('service_user', 'user') -%}
{%- set data_dir = qa.get('data_dir', '/rw/config/qubesair') -%}
{%- set db_path = qa.get('database_dsn', data_dir ~ '/qubes-air.db') -%}

{%- set bin_dir = data_dir ~ '/bin' -%}
{%- set bin_path = bin_dir ~ '/qubes-air-backup' -%}
{%- set env_file = data_dir ~ '/backup.env' -%}

{#- The archive directory is off the AppVM's own disks by definition; the default
    matches the unit text in the qubes-air repo's docs/disaster-recovery.md. -#}
{%- set offhost_dir = bk.get('offhost_dir', '/secure/offhost') -%}
{%- set keep = bk.get('keep', 14) -%}
{%- set schedule = bk.get('schedule', '*-*-* 03:30:00') -%}
{%- set run_at_boot = bk.get('run_at_boot', True) -%}
{%- set backup_user = bk.get('user', svc_user) -%}

{%- set bin_source = bk.get('binary_source', 'salt://qubesair/files/qubes-air-backup') -%}
{%- set bin_sha = bk.get('binary_sha256', '') -%}

{% if grains['nodename'] != 'dom0' %}
{% if not qa.get('enabled', False) %}

"qubesair-backup-qubesair-disabled-note":
  test.show_notification:
    - text: |
        qubesair.backup: cfg.qubesair.enabled is not True — nothing was deployed.

{% elif not bk.get('enabled', False) %}

"qubesair-backup-disabled-note":
  test.show_notification:
    - text: |
        qubesair.backup: cfg.qubesair.backup.enabled is not True — nothing was
        deployed. A console without backups is a console whose database exists
        in exactly one place.

        To enable, set in salt/config.jinja:

          "backup": {
            "enabled": True,
            "offhost_dir": "/secure/offhost",   # must be a MOUNTED off-host medium
            "keep": 14,                          # archives kept, newest by mtime
            "schedule": "*-*-* 03:30:00",
            "binary_sha256": "<sha256 of the qubes-air-backup binary>",
          }

        Then create the passphrase ONCE, in the console qube (not in this repo,
        and not in dom0):

          install -m 0600 -o {{ backup_user }} -g {{ backup_user }} /dev/null {{ env_file }}
          printf 'QUBES_AIR_BACKUP_PASSPHRASE=%s\n' "$(head -c 32 /dev/urandom | base64)" \
            | tee {{ env_file }} >/dev/null

        Copy that value to the off-host medium before trusting a single archive:
        without it the archives cannot be opened, and it is not recoverable from
        them.

{% else %}

{% if not bin_sha %}

{#- Same rule as the console binary, for the same reason: this one holds the
    console's provider credentials once decrypted, so "whatever sits at that path"
    is not good enough. -#}
"qubesair-backup-binary-sha-required":
  test.fail_without_changes:
    - name: |
        cfg.qubesair.backup.binary_sha256 is not set, and it has no default.

        qubes-air-backup is built from the qubes-air Go source. Nothing publishes
        it yet, so cross-compile it by hand into this repo's salt tree and pin it
        by digest:

          cd console/backend
          CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
            go build -trimpath -ldflags="-s -w" -o qubes-air-backup ./cmd/qubes-air-backup
          cp qubes-air-backup <this repo>/salt/qubesair/files/
          shasum -a 256 <this repo>/salt/qubesair/files/qubes-air-backup

        Then set cfg.qubesair.backup.binary_sha256 and re-run scripts/setup.sh.
    - failhard: True

{% endif %}

# --- 1. The binary ------------------------------------------------------------
# root-owned and root-writable, like the console binary: a bug in the console
# cannot rewrite what it is about to execute. The honest limit of that is the
# same too — data_dir is writable by {{ svc_user }} because the database lives in
# it, so this guards against accident, not against a determined process.
"qubesair-backup-data-dir":
  file.directory:
    - name: {{ data_dir }}
    - user: {{ svc_user }}
    - group: {{ svc_user }}
    - mode: '0700'
    - makedirs: True

"qubesair-backup-bin-dir":
  file.directory:
    - name: {{ bin_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True
    - require:
      - file: "qubesair-backup-data-dir"

"qubesair-backup-binary":
  file.managed:
    - name: {{ bin_path }}
    - source: {{ bin_source }}
    - source_hash: sha256={{ bin_sha }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "qubesair-backup-bin-dir"

# --- 2. The passphrase file: permissions enforced, content never touched ------
# replace: False is the whole point. It creates the file empty when it is absent
# and enforces owner and mode on every run, but it will not overwrite a file that
# already has content — the failure mode being avoided is an apply that silently
# rotates the key to every existing archive.
"qubesair-backup-env-file":
  file.managed:
    - name: {{ env_file }}
    - user: {{ backup_user }}
    - group: {{ backup_user }}
    - mode: '0600'
    - replace: False
    - require:
      - file: "qubesair-backup-data-dir"

# An empty file is not a passphrase. `test -s` makes "the operator has not done
# the one-time step yet" a failed run with the command in it, instead of a timer
# that fires every night and fails in a journal nobody reads.
"qubesair-backup-passphrase-present":
  cmd.run:
    - name: |
        cat >&2 <<'EOF'
        {{ env_file }} is missing or empty: the archives have no key.

        Run this ONCE in the console qube (it is not in this repo, and it is not
        recoverable from the archives):

          printf 'QUBES_AIR_BACKUP_PASSPHRASE=%s\n' "$(head -c 32 /dev/urandom | base64)" \
            > {{ env_file }} && chmod 0600 {{ env_file }}

        Then copy the value to the off-host medium. Re-running this command
        REPLACES the key, and every archive written before it becomes unopenable.
        EOF
        exit 1
    - unless: test -s {{ env_file }}
    - require:
      - file: "qubesair-backup-env-file"

# --- 3. systemd units ---------------------------------------------------------
# Written to the bind-dirs SOURCE, not to /etc/systemd/system — see the long note
# in console.sls: this AppVM's root volume is discarded on every shutdown, so a
# unit written to /etc/systemd/system now is not captured and is gone at the next
# boot.
"qubesair-backup-unit":
  file.managed:
    - name: /rw/bind-dirs/etc/systemd/system/qubes-air-backup.service
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.backup
        [Unit]
        Description=Qubes Air console backup (snapshot -> encrypt -> prune)
        After=qubes-air-console.service
        # The archive must land on off-host media: when the mount is absent this
        # fails the run on purpose rather than leaving the only copy on the disk
        # the backup exists to survive.
        RequiresMountsFor={{ offhost_dir }}

        [Service]
        Type=oneshot
        # 0600, one line: QUBES_AIR_BACKUP_PASSPHRASE=... — the key is never in
        # argv (visible in ps) and never in this unit file.
        EnvironmentFile={{ env_file }}
        # The same user the console runs as, so the database is readable without
        # widening its permissions. If the off-host medium is root-only, set
        # cfg.qubesair.backup.user: root — the env file's owner follows that same
        # key, so the two cannot drift apart.
        User={{ backup_user }}
        # No shell: the archive name is generated by the CLI (qubesair-<UTC>.qab).
        # systemd's unit specifiers have no date/time item — %Y is the unit file's
        # own directory, see systemd.unit(5) — so `$(date ...)` and `%Y%m%d` are
        # both wrong here.
        ExecStart={{ bin_path }} create -db {{ db_path }} -out-dir {{ offhost_dir }}
        # create and prune in ONE unit, in this order: `prune` alone would delete
        # down to `keep` with nothing new added, and a failed `create` stops the
        # rest of the unit, so a bad night cannot prune the good archives away.
        ExecStart={{ bin_path }} prune -dir {{ offhost_dir }} -keep {{ keep }}

"qubesair-backup-timer-unit":
  file.managed:
    - name: /rw/bind-dirs/etc/systemd/system/qubes-air-backup.timer
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by qubesair.backup
        [Unit]
        Description=Daily Qubes Air console backup

        [Timer]
        OnCalendar={{ schedule }}
        # Catches up a run missed WITHIN this boot session. It cannot catch one
        # missed across a reboot: the stamp lives on the root volume. The
        # rc.local block below is what covers that.
        Persistent=true
        Unit=qubes-air-backup.service

        [Install]
        WantedBy=timers.target

"qubesair-backup-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_qubesair_backup.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by qubesair.backup
        binds+=( '/etc/systemd/system/qubes-air-backup.service' )
        binds+=( '/etc/systemd/system/qubes-air-backup.timer' )

# Make both units real for THIS boot: the .conf above only takes effect at the
# next one, because bind-dirs.sh has long since run by the time salt gets here.
# `mountpoint -q ||` keeps it a no-op on later runs; the targets must exist first
# because mount --bind needs something to mount over.
"qubesair-backup-units-activate":
  cmd.run:
    - name: |
        set -e
        for unit in qubes-air-backup.service qubes-air-backup.timer; do
          target=/etc/systemd/system/$unit
          [ -e "$target" ] || : > "$target"
          chmod 0644 "$target"
          mountpoint -q "$target" \
            || mount --bind /rw/bind-dirs/etc/systemd/system/$unit "$target"
        done
        systemctl daemon-reload
    - runas: root
    - require:
      - file: "qubesair-backup-unit"
      - file: "qubesair-backup-timer-unit"
      - file: "qubesair-backup-bind-dirs"

"qubesair-backup-timer-running":
  cmd.run:
    - name: systemctl start qubes-air-backup.timer
    - runas: root
    - require:
      - cmd: "qubesair-backup-units-activate"
      - cmd: "qubesair-backup-passphrase-present"
      - file: "qubesair-backup-binary"

# --- 4. One backup per boot ---------------------------------------------------
# See the header: the timer alone cannot fire while the qube is down, and its
# missed-run stamp does not survive the root-volume reset. blockreplace rather
# than file.managed so this coexists with the blocks other states write into the
# same file.
"qubesair-backup-rc-local-exists":
  file.managed:
    - name: /rw/config/rc.local
    - user: root
    - group: root
    - mode: '0755'
    - replace: False
    - contents: |
        #!/bin/sh

"qubesair-backup-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> qubesair-backup >>>"
    - marker_end: "# <<< qubesair-backup <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by qubesair.backup — do not edit between markers.
        systemctl daemon-reload 2>/dev/null || true
        systemctl start qubes-air-backup.timer 2>/dev/null || true
{%- if run_at_boot %}
        # One backup per boot as well as the schedule: a timer cannot fire while
        # this AppVM is down, and the missed-run stamp does not survive a reboot.
        systemctl start qubes-air-backup.service 2>/dev/null || true
{%- endif %}
    - require:
      - file: "qubesair-backup-rc-local-exists"
      - file: "qubesair-backup-unit"
      - file: "qubesair-backup-timer-unit"

# --- 5. What the operator still has to do -------------------------------------
"qubesair-backup-notify":
  test.show_notification:
    - text: |
        qubesair.backup: binary, units and timer are in place; the timer is
        running and one backup also runs at every boot.

        Two things this state cannot do for you:

        1. Copy the passphrase off-host. Without it no archive can be opened,
           and it cannot be recovered from the archives themselves:

             # in dom0
             qvm-run -p {{ qa.get('qube', 'qubesair-console') }} \
               'cat {{ env_file }}' > /secure/offhost/backup-passphrase.txt

        2. Confirm that the newest archive actually restores. Run it now rather
           than the night you need it:

             sudo qubesctl --skip-dom0 --targets={{ qa.get('qube', 'qubesair-console') }} \
               state.apply qubesair.backup        # then, in the qube:
             systemctl start qubes-air-backup.service
             journalctl -u qubes-air-backup -n 50
             ls -lt {{ offhost_dir }}/*.qab | head

        Copying archives back into the directory: use `cp -p` (or `rsync -t`).
        Prune orders by mtime, so copies that lose their timestamp look like the
        newest archives and push the real newest one out of the keep window.
    - require:
      - cmd: "qubesair-backup-timer-running"

{% endif %}{# enabled #}
{% endif %}{# not dom0 #}
