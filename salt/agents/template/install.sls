{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the base development toolchain in tpl-agents (Debian minimal).

This state does NOT install Node or any coding agent: the agent bundle carries
a pinned Node runtime, the agent trees, and the pinned GUI application .debs.
Keeping those versions out of apt is what makes the bundle the unit of
versioning and rollback.

The template has no netvm; packages come through the Qubes update proxy.
agents.updates-proxy sends that proxy to cfg.agents.build.netvm, so this
apt leaves through the same VPN gateway as the bundle download.
qubes-core-agent-networking is installed for that proxy, not to give the
template a network.
#}

{% from 'config.jinja' import cfg with context %}
{% if grains['nodename'] != 'dom0' %}

{% if cfg.mirror.get('enabled', False) %}
include:
  - mgmt.mirror.debian
{% endif %}

"tpl-agents-update":
  pkg.uptodate:
    - refresh: True
{% if cfg.mirror.get('enabled', False) %}
    - require:
      - cmd: mirror-debian-repoint
{% endif %}

"tpl-agents-packages":
  pkg.installed:
    - require:
      - pkg: tpl-agents-update
    - pkgs:
      - qubes-core-agent-networking
      - qubes-core-agent-passwordless-root
      - ca-certificates
      - curl
      - wget
      - git
      - jq
      - xz-utils
      - tar
      - gzip
      - coreutils
      - findutils
      - python3
      - python3-venv
      - pipx
      - build-essential
      - ripgrep
      # Same CLIs as agents.template.tools. That state is the one to apply
      # on a template that should not be fully upgraded. Debian's source
      # package named helm is Emacs, so Helm is not listed here.
      - gh
      - kubectl
      - kustomize
      - openssh-client
      - gnupg
      # Split GPG 2 client. The server is the offline gpg qube. socat is the
      # forwarder for both qubes.Gpg2 and qubes.SshAgent. zenity is required
      # on a minimal template. See agents.split and templates.gpg.policy.
      - socat
      - split-gpg2
      - zenity
      - vim
      - tmux
      # qubes-run-terminal tries x-terminal-emulator before anything else, and
      # on debian-minimal that alternative is xterm. xfce4-terminal registers
      # a wrapper; the state below selects it.
      - xfce4-terminal
      - less
      - procps
      - htop
      - tree
      - man-db
      - bash-completion
      # Locales selected by cfg.agents.exits. The boot service switches LANG
      # per qube; the image has to have the locale already generated.
      - locales
      # GUI applications (Chrome, VS Code, Claude Desktop) arrive as pinned
      # .debs in the bundle; these are the menu/desktop helpers, while the
      # applications' own library dependencies are resolved by
      # install-agents.sh's apt-get -f install.
      - xdg-utils
      - desktop-file-utils
      - fonts-liberation
      - dbus-x11
      # WebRTC audio: the Qubes PulseAudio client plus tools. The AppVM must
      # ALSO have an audiovm (the repo's old examples set audiovm ""); see the
      # README. Chrome bundles WebRTC itself.
      - pulseaudio-qubes
      - pulseaudio-utils
      - pavucontrol

# Point Run Terminal at xfce4-terminal. The package registers
# /usr/bin/xfce4-terminal.wrapper; select it explicitly so a later package
# with a higher priority cannot put xterm back in front.
"tpl-agents-terminal":
  cmd.run:
    - name: update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper
    - unless: readlink -f /usr/bin/x-terminal-emulator | grep -q xfce4-terminal
    - require:
      - pkg: tpl-agents-packages

# Fallback only. dom0's zone is copied over this at every AppVM boot, and
# qubes-agents-exit.service then applies cfg.agents.exits for that qube.
"tpl-agents-timezone":
  timezone.system:
    - name: {{ cfg.agents.template.get('timezone', 'UTC') }}

{% for loc in cfg.agents.exits.values() | map(attribute='locale') | unique | list %}
"tpl-agents-locale-{{ loc }}":
  locale.present:
    - name: {{ loc }}
    - require:
      - pkg: tpl-agents-packages
{% endfor %}

"tpl-agents-default-locale":
  file.managed:
    - name: /etc/default/locale
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        LANG={{ cfg.agents.template.get('locale', 'en_US.UTF-8') }}
    - require:
{% for loc in cfg.agents.exits.values() | map(attribute='locale') | unique | list %}
      - locale: tpl-agents-locale-{{ loc }}
{% endfor %}

# Runs after qubes-early-vm-config, which has already copied dom0's zone.
# vm-config.* features are the per-qube exit binding set by agents.exit.
"tpl-agents-exit-script":
  file.managed:
    - name: /usr/lib/qubes-agents/apply-exit.sh
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        # Managed by agents.template.install. Apply this qube's VPN-exit
        # timezone and locale from vm-config features. Missing features leave
        # the image fallback in place (the template itself has neither).
        set -eu
        tz=$(qubesdb-read /vm-config/timezone 2>/dev/null || true)
        loc=$(qubesdb-read /vm-config/locale 2>/dev/null || true)
        if [ -n "$tz" ]; then
            case "$tz" in
                *..*|/*|*[!A-Za-z0-9_+/-]*)
                    echo "agents-exit: rejected timezone: $tz" >&2
                    exit 1
                    ;;
            esac
            if [ ! -e "/usr/share/zoneinfo/$tz" ]; then
                echo "agents-exit: zoneinfo missing: $tz" >&2
                exit 1
            fi
            ln -sfn "/usr/share/zoneinfo/$tz" /etc/localtime
            printf '%s\n' "$tz" > /etc/timezone
            echo "agents-exit: timezone $tz"
        fi
        if [ -n "$loc" ]; then
            case "$loc" in
                *[!A-Za-z0-9._@-]*)
                    echo "agents-exit: rejected locale: $loc" >&2
                    exit 1
                    ;;
            esac
            printf 'LANG=%s\n' "$loc" > /etc/default/locale
            printf 'LANG=%s\n' "$loc" > /etc/locale.conf
            echo "agents-exit: locale $loc"
        fi

"tpl-agents-exit-unit":
  file.managed:
    - name: /etc/systemd/system/qubes-agents-exit.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Apply timezone and locale for this qube's VPN exit
        After=qubes-early-vm-config.service
        Before=systemd-user-sessions.service

        [Service]
        Type=oneshot
        ExecStart=/usr/lib/qubes-agents/apply-exit.sh
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: tpl-agents-exit-script

"tpl-agents-exit-enable":
  cmd.run:
    - name: systemctl enable qubes-agents-exit.service
    - unless: systemctl is-enabled --quiet qubes-agents-exit.service
    - require:
      - file: tpl-agents-exit-unit

# These qubes run Claude on a US exit. No zh_CN locale and no Chinese IME.
# Purge a copy left by an earlier apply, and drop the IM variables it wrote.
"tpl-agents-fcitx-removed":
  pkg.purged:
    - pkgs:
      - fcitx5
      - fcitx5-chinese-addons
      - fcitx5-frontend-gtk3
      - fcitx5-frontend-qt5
    - require:
      - pkg: tpl-agents-packages

"tpl-agents-fcitx-profile-absent":
  file.absent:
    - name: /etc/profile.d/fcitx.sh

"tpl-agents-fcitx-environment-clear":
  cmd.run:
    - name: sed -i '/# >>> fcitx5 >>>/,/# <<< fcitx5 <<</d' /etc/environment
    - onlyif: grep -q '>>> fcitx5 >>>' /etc/environment

# Login qubes are probed for installed Chinese fonts. fonts-noto-cjk
# registers Noto Sans CJK SC/TC and Noto Serif CJK SC; fonts-noto-cjk-extra
# adds the mono faces. WenQuanYi and AR PL are the other packaged families
# those probes name. fonts-liberation stays; it does not register those
# families. Purge only packages that are actually installed,
# so a name missing from a minimal apt list does not fail the state.
"tpl-agents-cjk-fonts-removed":
  cmd.run:
    - name: |
        set -eu
        pkgs="fonts-noto-cjk fonts-noto-cjk-extra fonts-wqy-microhei fonts-wqy-zenhei fonts-arphic-ukai fonts-arphic-uming fonts-arphic-gbsn00lp fonts-arphic-gkai00mp fonts-arphic-bkai00mp fonts-arphic-bsmi00lp"
        remove=""
        for p in $pkgs; do
          if dpkg -s "$p" >/dev/null 2>&1; then
            remove="$remove $p"
          fi
        done
        if [ -n "$remove" ]; then
          DEBIAN_FRONTEND=noninteractive apt-get purge -y $remove
        fi
        fc-cache -f >/dev/null 2>&1 || true
    - unless: |
        bash -c 'for p in fonts-noto-cjk fonts-noto-cjk-extra fonts-wqy-microhei fonts-wqy-zenhei fonts-arphic-ukai fonts-arphic-uming fonts-arphic-gbsn00lp fonts-arphic-gkai00mp fonts-arphic-bkai00mp fonts-arphic-bsmi00lp; do
          dpkg -s "$p" >/dev/null 2>&1 && exit 1
        done
        fc-list : family | grep -E -q "Noto (Sans|Serif|Sans Mono) CJK|WenQuanYi|AR PL" && exit 1
        exit 0'
    - require:
      - pkg: tpl-agents-packages

# Chrome gathers a STUN candidate for the VPN exit address unless this is
# set. With no browser proxy, disable_non_proxied_udp gathers nothing, so
# a page that treats any numeric ICE address as a leak stays quiet.
# WebRtcIPHandling is the policy name Chrome 156 reads.
"tpl-agents-chrome-webrtc-policy":
  file.managed:
    - name: /etc/opt/chrome/policies/managed/webrtc.json
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        {
          "WebRtcIPHandling": "disable_non_proxied_udp"
        }

{% endif %}
