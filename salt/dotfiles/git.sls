{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Git configuration for specific AppVMs (not templates).

Usage:
  sudo qubesctl --skip-dom0 --targets=slchris-project state.apply dotfiles.git

Configure in pillar (user.sls):
  qubes:
    slchris-project:
      git:
        name: "Your Name"
        email: "your@email.com"
#}

{% if grains['nodename'] != 'dom0' %}

{% set qube_name = grains['nodename'] %}
{% set git_config = salt['pillar.get']('qubes:' ~ qube_name ~ ':git', {}) %}

{% if git_config %}
{% set git_name = git_config.get('name', 'Your Name') %}
{% set git_email = git_config.get('email', 'your.email@example.com') %}
{% set git_signingkey = git_config.get('signingkey', '') %}

"dotfiles-git-config-dir":
  file.directory:
    - name: /home/user
    - user: user
    - group: user
    - mode: '0700'
    - makedirs: True

"dotfiles-git-config":
  file.managed:
    - name: /home/user/.gitconfig
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        [user]
            name = {{ git_name }}
            email = {{ git_email }}
        {% if git_signingkey %}
            signingkey = {{ git_signingkey }}
        [commit]
            gpgsign = true
        {% endif %}
        [init]
            defaultBranch = main
        [core]
            editor = vim
        [pull]
            rebase = false
        [color]
            ui = auto

{% else %}

"dotfiles-git-no-config":
  test.show_notification:
    - text: |
        No git configuration found for qube '{{ qube_name }}'.
        Add configuration in pillar:
          qubes:
            {{ qube_name }}:
              git:
                name: "Your Name"
                email: "your@email.com"

{% endif %}
{% endif %}
