{# SPDX-License-Identifier: MIT #}
{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set qube = qa.get('qube', 'qubesair-console') -%}
{% if grains['nodename'] == qube and qa.get('enabled', False) %}

"qubesair-console-ingress-directory":
  file.directory:
    - name: /rw/config/qubesair-ingress
    - user: root
    - group: root
    - mode: '0755'

"qubesair-console-ingress-helper":
  file.managed:
    - name: /rw/config/qubesair-ingress/apply.py
    - source: salt://qubesair/files/console-ingress.py
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "qubesair-console-ingress-directory"

"qubesair-console-ingress-config":
  file.managed:
    - name: /rw/config/qubesair-ingress/config.json
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        {{ {'enabled': qa.get('allow_gateway_ingress', False), 'qube': qube, 'listen': qa.get('listen', '127.0.0.1:8080')} | tojson }}
    - require:
      - file: "qubesair-console-ingress-directory"

"qubesair-console-ingress-firewall-file":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - user: root
    - group: root
    - mode: '0755'
    - replace: False
    - contents: |
        #!/bin/sh

"qubesair-console-ingress-hook":
  file.blockreplace:
    - name: /rw/config/qubes-firewall-user-script
    - marker_start: "# >>> qubesair console ingress >>>"
    - marker_end: "# <<< qubesair console ingress <<<"
    - append_if_not_found: True
    - content: |
        /rw/config/qubesair-ingress/apply.py
    - require:
      - file: "qubesair-console-ingress-firewall-file"
      - file: "qubesair-console-ingress-helper"
      - file: "qubesair-console-ingress-config"

"qubesair-console-ingress-apply":
  cmd.run:
    - name: /rw/config/qubesair-ingress/apply.py
    - stateful: True
    - require:
      - file: "qubesair-console-ingress-hook"

{% endif %}
