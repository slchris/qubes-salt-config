{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the relay-cert ISSUER on the console qube (path b — see
qubes-air/docs/grpc-transport-design.md §0.5). Runs IN the console qube.

Delivers:
  - /usr/local/bin/issue-relay-cert (SHA-pinned) — signs a relay's CSR with the
    console CA, pinning the certificate CN to the calling qube's identity;
  - /etc/qubes-rpc/qubesair.IssueRelayCert — the qrexec service the relay calls,
    which sources the console's secrets.env and execs the binary. dom0 policy
    (mgmt.remotevm.grpc-policy) gates which qube may call it.

The console stays a pure CONTROL plane: it signs certificates, it does not relay
RPCs. secrets.env and the database it reads are already the console's own.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<console> state.apply mgmt.remotevm.grpc-console
#}

{%- from 'config.jinja' import cfg with context -%}
{%- from 'qubesair/macros/artifacts.jinja' import local_source, stage -%}
{%- set csr = cfg.remotevm.get('grpc', {}).get('csr', {}) -%}
{%- set runtime_dir = '/rw/config/qubesair-rpc' -%}

{% if grains['nodename'] != 'dom0' %}
{% if csr.get('enabled', False) %}

{% if not csr.get('issue_bin_sha256') or not csr.get('list_endpoints_sha256') %}
"grpc-console-issue-sha-required":
  test.fail_without_changes:
    - name: |
        Pin both issue_bin_sha256 and list_endpoints_sha256 before applying.
    - failhard: True
{% else %}

include:
  - qubesair.artifact-fetch

# Runtime code is root-owned and outside the console's user-owned data tree.
"grpc-console-runtime-dir":
  file.directory:
    - name: {{ runtime_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

# The issuer signs with the console CA, so like the console binary it is
# root-owned: a process running as the service user must not be able to rewrite
# the tool that wields the CA.
{{ stage('issuer', csr.issue_bin_source, csr.issue_bin_sha256, ['grpc-console-issue-bin']) }}

"grpc-console-issue-bin":
  file.managed:
    - name: {{ runtime_dir }}/issue-relay-cert
    - source: {{ local_source('issuer', csr.issue_bin_source) }}
    - source_hash: sha256={{ csr.issue_bin_sha256 }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "grpc-console-runtime-dir"

"grpc-console-issue-service":
  file.managed:
    - name: {{ runtime_dir }}/qubesair.IssueRelayCert
    - source: salt://mgmt/remotevm/files/qubesair.IssueRelayCert
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "grpc-console-runtime-dir"

# Endpoint lister for the relay to pull (path b, endpoint delivery). It reads
# only qube names + addresses from the database — no CA, no secrets — so unlike
# the issuer it is not privileged beyond database read.
{{ stage('endpoints', csr.list_endpoints_source, csr.list_endpoints_sha256, ['grpc-console-list-endpoints-bin']) }}

"grpc-console-list-endpoints-bin":
  file.managed:
    - name: {{ runtime_dir }}/list-endpoints
    - source: {{ local_source('endpoints', csr.list_endpoints_source) }}
    - source_hash: sha256={{ csr.get('list_endpoints_sha256', '') }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "grpc-console-runtime-dir"

"grpc-console-endpoints-service":
  file.managed:
    - name: {{ runtime_dir }}/qubesair.RemoteEndpoints
    - source: salt://mgmt/remotevm/files/qubesair.RemoteEndpoints
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "grpc-console-runtime-dir"

"grpc-console-boot":
  file.managed:
    - name: {{ runtime_dir }}/boot.sh
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/sh
        set -eu
        mkdir -p /usr/local/bin /etc/qubes-rpc
        ln -sf {{ runtime_dir }}/issue-relay-cert /usr/local/bin/issue-relay-cert
        ln -sf {{ runtime_dir }}/list-endpoints /usr/local/bin/list-endpoints
        ln -sf {{ runtime_dir }}/qubesair.IssueRelayCert /etc/qubes-rpc/qubesair.IssueRelayCert
        ln -sf {{ runtime_dir }}/qubesair.RemoteEndpoints /etc/qubes-rpc/qubesair.RemoteEndpoints
    - require:
      - file: "grpc-console-runtime-dir"

"grpc-console-rc-local-exists":
  file.managed:
    - name: /rw/config/rc.local
    - user: root
    - group: root
    - mode: '0755'
    - replace: False
    - contents: |
        #!/bin/sh

"grpc-console-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> qubesair grpc-console >>>"
    - marker_end: "# <<< qubesair grpc-console <<<"
    - content: "{{ runtime_dir }}/boot.sh"
    - append_if_not_found: True
    - require:
      - file: "grpc-console-rc-local-exists"

"grpc-console-activate":
  cmd.run:
    - name: {{ runtime_dir }}/boot.sh
    - runas: root
    - require:
      - file: "grpc-console-issue-bin"
      - file: "grpc-console-issue-service"
      - file: "grpc-console-list-endpoints-bin"
      - file: "grpc-console-endpoints-service"
      - file: "grpc-console-boot"

{% endif %}
{% endif %}
{% endif %}
