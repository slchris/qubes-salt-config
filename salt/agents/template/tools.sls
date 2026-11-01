{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the small CLI set slchris-project needs on top of tpl-agents.

agents.template.install upgrades the whole template. This state installs
only GitHub CLI, kubectl, kustomize, Helm, age, and sops. Apt leaves
through sys-bwg-net (agents.updates-proxy). Shut the template down
afterwards. A running AppVM keeps the old root until it is restarted.

Debian ships gh, kubectl, kustomize, and age. The Debian source package
named helm is Emacs (elpa-helm), so Helm comes from the upstream apt repo.
That repo also publishes Helm 4. tools.helm in agents/lock.yml stays on
3.x, and this state holds the package so a later apt run does not cross
that major version. Debian's kustomize binary reports its version as
"(devel)"; the package version is what gets checked.

Debian has no Mozilla sops package. The packages named sops, sos, and
orca-sops are different software and must not be installed. tools.sops
in agents/lock.yml is the upstream linux amd64 binary, sha256-pinned,
installed to /usr/bin/sops. An AppVM mounts its private volume over
/usr/local, so a binary left there is invisible after the AppVM boots.

  sudo qubesctl --skip-dom0 --targets=tpl-agents state.apply agents.template.tools
#}

{% import_yaml 'agents/lock.yml' as lock %}
{% set helm = lock['tools']['helm'] %}
{% set sops = lock['tools']['sops'] %}

{% if grains['nodename'] != 'dom0' %}

"tpl-agents-tools-debian":
  pkg.installed:
    - refresh: True
    - pkgs:
      - gh
      - kubectl
      - kustomize
      - age

"tpl-agents-tools-helm-key":
  cmd.run:
    - name: |
        set -euo pipefail
        expected=DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6
        fpr_of() {
          local dir got
          dir=$(mktemp -d)
          got=$(gpg --homedir "$dir" --batch --pinentry-mode error \
            --import --import-options=show-only --with-colons "$1" \
            | awk -F: '$1 == "fpr" {print $10; exit}')
          rm -rf "$dir"
          printf '%s\n' "$got"
        }
        if [ -s /etc/apt/keyrings/helm.asc ]; then
          got=$(fpr_of /etc/apt/keyrings/helm.asc)
          if [ "$got" = "$expected" ]; then
            echo "helm key ok"
            exit 0
          fi
          echo "helm key on disk does not match"
          exit 1
        fi
        tmp=$(mktemp)
        curl -fsSL -x http://127.0.0.1:8082 --max-time 60 \
          https://packages.buildkite.com/helm-linux/helm-debian/gpgkey -o "$tmp"
        got=$(fpr_of "$tmp")
        if [ "$got" != "$expected" ]; then
          echo "helm key download does not match"
          rm -f "$tmp"
          exit 1
        fi
        install -d -m 0755 /etc/apt/keyrings
        install -m 0644 "$tmp" /etc/apt/keyrings/helm.asc
        rm -f "$tmp"
        echo "helm key installed"
    - require:
      - pkg: tpl-agents-tools-debian

"tpl-agents-tools-helm-source":
  file.managed:
    - name: /etc/apt/sources.list.d/helm-stable-debian.sources
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by agents.template.tools
        Types: deb
        URIs: https://packages.buildkite.com/helm-linux/helm-debian/any/
        Suites: any
        Components: main
        Signed-By: /etc/apt/keyrings/helm.asc
    - require:
      - cmd: tpl-agents-tools-helm-key

"tpl-agents-tools-helm":
  cmd.run:
    - name: |
        set -euo pipefail
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades helm={{ helm.apt_version }}
        apt-mark hold helm
    - unless: helm version --short 2>/dev/null | grep -Eq '^v{{ helm.version | replace(".", "\\.") }}([^0-9]|$)'
    - require:
      - file: tpl-agents-tools-helm-source

"tpl-agents-tools-sops":
  cmd.run:
    - name: |
        set -euo pipefail
        expected={{ sops.sha256 }}
        if [ -f /usr/local/bin/sops ] \
            && [ "$(sha256sum /usr/local/bin/sops | awk '{print $1}')" = "$expected" ]; then
          install -m 0755 /usr/local/bin/sops /usr/bin/sops
          rm -f /usr/local/bin/sops
          exit 0
        fi
        tmp=$(mktemp)
        curl -fsSL -x http://127.0.0.1:8082 --max-time 180 \
          -o "$tmp" \
          "{{ sops.url }}"
        got=$(sha256sum "$tmp" | awk '{print $1}')
        if [ "$got" != "$expected" ]; then
          echo "sops download does not match"
          rm -f "$tmp"
          exit 1
        fi
        install -m 0755 "$tmp" /usr/bin/sops
        rm -f "$tmp" /usr/local/bin/sops
        test "$(sha256sum /usr/bin/sops | awk '{print $1}')" = "$expected"
    - unless: sha256sum /usr/bin/sops | awk '{print $1}' | grep -qx {{ sops.sha256 }}
    - require:
      - pkg: tpl-agents-tools-debian

"tpl-agents-tools-verify":
  cmd.run:
    - name: |
        set -euo pipefail
        exec 2>&1
        gh --version | head -n 1
        kubectl version --client=true
        kustomize version
        dpkg-query -W -f 'kustomize ${Version}\n' kustomize
        short=$(helm version --short)
        printf '%s\n' "$short"
        printf '%s\n' "$short" | grep -Eq '^v{{ helm.version | replace(".", "\\.") }}([^0-9]|$)'
        apt-mark showhold | grep -qx helm
        if dpkg-query -W -f '${Status}' elpa-helm 2>/dev/null | grep -q 'install ok installed'; then
          echo "refusing Debian elpa-helm"
          exit 1
        fi
        age --version
        test "$(sha256sum /usr/bin/sops | awk '{print $1}')" = {{ sops.sha256 }}
        help=$(mktemp)
        sops --help > "$help"
        grep -Eq '(^|[^0-9]){{ sops.version }}([^0-9]|$)' "$help"
        rm -f "$help"
        if dpkg-query -W -f '${Status}' sops 2>/dev/null | grep -q 'install ok installed'; then
          echo "refusing Debian package sops"
          exit 1
        fi
    - require:
      - cmd: tpl-agents-tools-helm
      - cmd: tpl-agents-tools-sops

{% endif %}
