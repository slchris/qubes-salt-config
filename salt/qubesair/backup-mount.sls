{# SPDX-License-Identifier: MIT
Persistent SSHFS storage for encrypted archives. Apply to the template as well
as the running Console so sshfs survives the AppVM root reset. Shut down the
updated template before restarting the Console to commit its new root snapshot.
The private key
and trusted known_hosts are provisioned separately; this state never renders
or replaces either secret. The NAS account must be confined to its archive
folder by the SSH server. #}
{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set bk = qa.get('backup', {}) -%}
{%- set remote = bk.get('sshfs', {}) -%}
{%- set data_dir = qa.get('data_dir', '/rw/config/qubesair') -%}
{%- set key_dir = data_dir ~ '/backup-ssh' -%}
{%- set offhost_dir = bk.get('offhost_dir', '/secure/offhost') -%}
{%- set backup_user = bk.get('user', qa.get('service_user', 'user')) -%}
{% if grains['nodename'] != 'dom0' and qa.get('enabled', False) and bk.get('enabled', False) and remote.get('enabled', False) %}
{% if offhost_dir != '/secure/offhost' %}
"qubesair-backup-mount-path-required":
  test.fail_without_changes:
    - name: The SSHFS mount state requires offhost_dir=/secure/offhost.
    - failhard: True
{% else %}
"qubesair-backup-sshfs-package":
  pkg.installed:
    - name: sshfs

{% if grains['nodename'] == qa.get('qube', 'qubesair-console') %}
{%- set account = salt['user.info'](backup_user) %}
# Salt's makedirs otherwise gives /secure the child's 0700 mode, preventing
# the non-root backup service from reaching even a correctly mounted SSHFS.
"qubesair-backup-mount-parent":
  file.directory:
    - name: /secure
    - user: root
    - group: root
    - mode: '0711'

"qubesair-backup-mountpoint":
  file.directory:
    - name: /secure/offhost
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True
    - unless: mountpoint -q /secure/offhost
    - require:
      - file: qubesair-backup-mount-parent

"qubesair-backup-ssh-identity":
  cmd.run:
    - name: |
        set -eu
        test -s '{{ key_dir }}/id_ed25519'
        test -s '{{ key_dir }}/known_hosts'
        test "$(stat -c '%a' '{{ key_dir }}/id_ed25519')" = 600
    - stateful: False

"qubesair-backup-mount-unit":
  file.managed:
    - name: /rw/bind-dirs/etc/systemd/system/secure-offhost.mount
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by qubesair.backup-mount
        [Unit]
        Description=Qubes Air encrypted archive storage over SSH
        Wants=network-online.target
        After=network-online.target

        [Mount]
        What={{ remote.get('user', '') }}@{{ remote.get('host', '') }}:{{ remote.get('path', '/archives') }}
        Where=/secure/offhost
        Type=fuse.sshfs
        Options=_netdev,port={{ remote.get('port', 22) }},IdentityFile={{ key_dir }}/id_ed25519,UserKnownHostsFile={{ key_dir }}/known_hosts,StrictHostKeyChecking=yes,BatchMode=yes,ConnectTimeout=10,ServerAliveInterval=15,ServerAliveCountMax=3,reconnect,allow_other,default_permissions,uid={{ account['uid'] }},gid={{ account['gid'] }}
        TimeoutSec=30
    - require:
      - cmd: qubesair-backup-ssh-identity

"qubesair-backup-mount-bind-dirs":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/52_qubesair_backup_mount.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by qubesair.backup-mount
        binds+=( '/etc/systemd/system/secure-offhost.mount' )

"qubesair-backup-mount-activate":
  cmd.run:
    - name: |
        set -eu
        target=/etc/systemd/system/secure-offhost.mount
        [ -e "$target" ] || : > "$target"
        mountpoint -q "$target" \
          || mount --bind /rw/bind-dirs/etc/systemd/system/secure-offhost.mount "$target"
        systemctl daemon-reload
    - require:
      - file: qubesair-backup-mount-unit
      - file: qubesair-backup-mount-bind-dirs
      - file: qubesair-backup-mountpoint
      - pkg: qubesair-backup-sshfs-package

"qubesair-backup-mount-running":
  service.running:
    - name: secure-offhost.mount
    - require:
      - cmd: qubesair-backup-mount-activate
{% endif %}
{% endif %}
{% endif %}
