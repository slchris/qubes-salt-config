{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
#}

{% from 'config.jinja' import cfg with context %}

{% if grains['nodename'] != 'dom0' %}

{% set default_shell = cfg.user.shell.get('default', 'bash') %}

"dotfiles-shell-bashrc":
  file.managed:
    - name: /home/user/.bashrc
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # ~/.bashrc

        # If not running interactively, don't do anything
        case $- in
            *i*) ;;
              *) return;;
        esac

        # History settings
        HISTCONTROL=ignoreboth
        HISTSIZE=10000
        HISTFILESIZE=20000
        shopt -s histappend

        # Check window size after each command
        shopt -s checkwinsize

        # Enable color support
        if [ -x /usr/bin/dircolors ]; then
            test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
            alias ls='ls --color=auto'
            alias grep='grep --color=auto'
        fi

        # Aliases
        alias ll='ls -alF'
        alias la='ls -A'
        alias l='ls -CF'

        # Prompt
        PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

        # Enable programmable completion
        if ! shopt -oq posix; then
          if [ -f /usr/share/bash-completion/bash_completion ]; then
            . /usr/share/bash-completion/bash_completion
          elif [ -f /etc/bash_completion ]; then
            . /etc/bash_completion
          fi
        fi

        # Custom PATH
        export PATH="$HOME/.local/bin:$PATH"

"dotfiles-shell-profile":
  file.managed:
    - name: /home/user/.profile
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        # ~/.profile

        # Set PATH
        if [ -d "$HOME/.local/bin" ] ; then
            PATH="$HOME/.local/bin:$PATH"
        fi

        # Source bashrc for bash
        if [ -n "$BASH_VERSION" ]; then
            if [ -f "$HOME/.bashrc" ]; then
                . "$HOME/.bashrc"
            fi
        fi

"dotfiles-shell-local-bin":
  file.directory:
    - name: /home/user/.local/bin
    - user: user
    - group: user
    - mode: '0755'
    - makedirs: True

{% endif %}
