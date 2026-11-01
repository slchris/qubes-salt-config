{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Let the GUI domain's Qubes Update app call the dom0-only updater (runs IN dom0).

`qubes-vm-update` is packaged only for dom0 (`qubes-vmupdate`; it is not in the
VM repositories) and the Qubes GUI-domain docs list "Cannot update dom0 from
sys-gui" (QubesOS/qubes-issues#8934). The stock app therefore dies in the GUI
domain with FileNotFoundError before it can draw its window.

This state installs a narrow qrexec bridge:

  * `/etc/qubes-rpc/qubes.UpdateGui` runs `/usr/bin/qubes-vm-update` with an
    argv array read from stdin. It allows only the flags the Qubes Update GUI
    emits, validates every value, and never invokes a shell.
  * `/etc/qubes/policy.d/50-gui-updater.policy` permits only the GUI domain
    (cfg.gui_vnc.qube) to call that service.
  * mgmt.gui-vnc.install installs the GUI-domain wrapper named
    `qubes-vm-update`, which forwards to this service and demultiplexes
    stderr/progress and the exit code back to the app.

Security: the bridge lets the GUI domain trigger updates, including dom0,
through dom0's updater. It does NOT grant arbitrary dom0 command execution —
the service accepts only the updater flags below and execs the CLI directly.
Set cfg.gui_vnc.updater_bridge to False and re-apply both states to revoke it:
this state removes the service and policy; mgmt.gui-vnc.install removes the
wrapper.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.updater-bridge
  sudo qubesctl --skip-dom0 --targets=<template> state.apply mgmt.gui-vnc.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) and gv.get('updater_bridge', False) %}

"gui-vnc-updater-bridge-service":
  file.managed:
    - name: /etc/qubes-rpc/qubes.UpdateGui
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/usr/bin/python3
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.updater-bridge.
        #
        # Runs the dom0-only qubes-vm-update on behalf of the GUI domain. The
        # caller sends one CLI argument per line on stdin. Only the arguments
        # the Qubes Update GUI emits are accepted; everything is exec'd as an
        # argv array, never through a shell. stderr is multiplexed onto stdout
        # with a marker so the caller can restore it on its own stderr (qrexec
        # does not relay the service's stderr).
        import os
        import re
        import signal
        import subprocess
        import sys
        import threading

        STDERR_MARK = b"\x01QSC-STDERR\x01"
        EXIT_MARK = b"\x01QSC-EXIT\x01"
        CLI = "/usr/bin/qubes-vm-update"

        BOOL_FLAGS = {
            "--help",
            "--dry-run",
            "--quiet",
            "--show-output",
            "--just-print-progress",
            "--force-update",
            "--templates",
            "--standalones",
            "--apps",
            "--all",
            "--dom0",
            "--no-refresh",
            "--no-cleanup",
            "--signal-no-updates",
        }
        VALUE_FLAGS = {
            "--update-if-stale": re.compile(r"^[0-9]+$"),
            "--max-concurrency": re.compile(r"^[0-9]+$"),
            "--targets": re.compile(r"^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$"),
            "--skip": re.compile(r"^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$"),
        }


        def write_all(fd, data):
            while data:
                written = os.write(fd, data)
                data = data[written:]


        def emit_stderr(message):
            try:
                write_all(1, STDERR_MARK + message + b"\n")
            except (BrokenPipeError, OSError):
                pass


        def finish(rc, message=None):
            if message:
                emit_stderr(message)
            try:
                write_all(1, EXIT_MARK + str(rc).encode() + b"\n")
            except (BrokenPipeError, OSError):
                pass
            sys.exit(rc)


        def parse_args():
            raw = sys.stdin.buffer.read()
            tokens = [os.fsdecode(token) for token in raw.split(b"\n") if token]
            args = []
            i = 0
            while i < len(tokens):
                token = tokens[i]
                if token in BOOL_FLAGS:
                    args.append(token)
                    i += 1
                elif token in VALUE_FLAGS:
                    if i + 1 >= len(tokens) or not VALUE_FLAGS[token].match(
                        tokens[i + 1]
                    ):
                        finish(
                            126,
                            b"qubes.UpdateGui: invalid value for "
                            + token.encode(),
                        )
                    args.extend((token, tokens[i + 1]))
                    i += 2
                else:
                    finish(
                        126,
                        b"qubes.UpdateGui: argument not allowed: "
                        + token.encode(),
                    )
            return args


        def main():
            args = parse_args()
            if not os.access(CLI, os.X_OK):
                finish(127, b"qubes.UpdateGui: %s is not executable" % CLI.encode())
            try:
                proc = subprocess.Popen(
                    [CLI, *args],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            except OSError as err:
                finish(127, ("qubes.UpdateGui: cannot start %s: %s"
                             % (CLI, err)).encode())

            lock = threading.Lock()

            def relay(stream, prefix):
                try:
                    for line in iter(stream.readline, b""):
                        with lock:
                            write_all(1, prefix + line)
                except (BrokenPipeError, OSError):
                    try:
                        proc.send_signal(signal.SIGINT)
                    except ProcessLookupError:
                        pass
                finally:
                    try:
                        stream.close()
                    except OSError:
                        pass

            out_thread = threading.Thread(
                target=relay, args=(proc.stdout, b""), daemon=True
            )
            err_thread = threading.Thread(
                target=relay, args=(proc.stderr, STDERR_MARK), daemon=True
            )
            out_thread.start()
            err_thread.start()

            def forward(signum, _frame):
                try:
                    proc.send_signal(signum)
                except ProcessLookupError:
                    pass

            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, forward)

            rc = proc.wait()
            out_thread.join()
            err_thread.join()
            finish(rc)


        if __name__ == "__main__":
            main()

"gui-vnc-updater-bridge-policy":
  file.managed:
    - name: /etc/qubes/policy.d/50-gui-updater.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.updater-bridge. The service only accepts the
        # Qubes Update GUI's own flags; it is not a general dom0 shell.
        qubes.UpdateGui  *  {{ qube }}  dom0  allow

{% else %}

"gui-vnc-updater-bridge-service-absent":
  file.absent:
    - name: /etc/qubes-rpc/qubes.UpdateGui

"gui-vnc-updater-bridge-policy-absent":
  file.absent:
    - name: /etc/qubes/policy.d/50-gui-updater.policy

"gui-vnc-updater-bridge-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.updater-bridge: cfg.gui_vnc.updater_bridge is False (or
        gui_vnc.enabled is False) — removed the qubes.UpdateGui service and
        policy.

{% endif %}
{% endif %}
