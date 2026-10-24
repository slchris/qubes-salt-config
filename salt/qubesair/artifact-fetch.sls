{# SPDX-License-Identifier: MIT #}
{% if grains['nodename'] != 'dom0' %}
"qubesair-artifact-root":
  file.directory:
    - name: /rw/config/qubesair-artifacts
    - user: root
    - group: root
    - mode: '0755'

{% for subdir in ['requests', 'cache'] %}
"qubesair-artifact-{{ subdir }}":
  file.directory:
    - name: /rw/config/qubesair-artifacts/{{ subdir }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "qubesair-artifact-root"
{% endfor %}

"qubesair-artifact-helper":
  file.managed:
    - name: /rw/config/qubesair-artifacts/fetch.py
    - source: salt://qubesair/files/fetch-artifact.py
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "qubesair-artifact-root"
{% endif %}
