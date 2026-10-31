{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Let the gpg qube user open the CanoKey through pcscd.

pcscd 2.3 asks polkit for access_pcsc and access_card. A qrexec session
is not a logind seat, so the default policy refuses it and scdaemon
reports "No such device". This rule is only the local user in this
template. No packages are installed.

  sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.pcscd

Shut tpl-gpg afterwards. A running gpg AppVM keeps the old template root
until it is restarted.
#}

{% if grains['nodename'] != 'dom0' %}

"gpg-pcscd-polkit":
  file.managed:
    - name: /etc/polkit-1/rules.d/40-pcscd-gpg.rules
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - dir_mode: '0755'
    - contents: |
        polkit.addRule(function(action, subject) {
            if (action.id.indexOf("org.debian.pcsc-lite.") === 0 && subject.user == "user") {
                return polkit.Result.YES;
            }
        });

{% endif %}
