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
{%- set csr = cfg.remotevm.get('grpc', {}).get('csr', {}) -%}

{% if grains['nodename'] != 'dom0' %}
{% if csr.get('enabled', False) %}

{% if not csr.get('issue_bin_sha256') %}
"grpc-console-issue-sha-required":
  test.fail_without_changes:
    - name: |
        cfg.remotevm.grpc.csr.issue_bin_sha256 is empty. Publish issue-relay-cert
        and pin its digest before applying, exactly like the console binary:
          shasum -a 256 issue-relay-cert
    - failhard: True
{% else %}

# The issuer signs with the console CA, so like the console binary it is
# root-owned: a process running as the service user must not be able to rewrite
# the tool that wields the CA.
"grpc-console-issue-bin":
  file.managed:
    - name: /usr/local/bin/issue-relay-cert
    - source: {{ csr.issue_bin_source }}
    - source_hash: sha256={{ csr.issue_bin_sha256 }}
    - user: root
    - group: root
    - mode: '0755'

"grpc-console-issue-service":
  file.managed:
    - name: /etc/qubes-rpc/qubesair.IssueRelayCert
    - source: salt://mgmt/remotevm/files/qubesair.IssueRelayCert
    - user: root
    - group: root
    - mode: '0755'

# Endpoint lister for the relay to pull (path b, endpoint delivery). It reads
# only qube names + addresses from the database — no CA, no secrets — so unlike
# the issuer it is not privileged beyond database read.
"grpc-console-list-endpoints-bin":
  file.managed:
    - name: /usr/local/bin/list-endpoints
    - source: {{ csr.list_endpoints_source }}
    - source_hash: sha256={{ csr.get('list_endpoints_sha256', '') }}
    - user: root
    - group: root
    - mode: '0755'

"grpc-console-endpoints-service":
  file.managed:
    - name: /etc/qubes-rpc/qubesair.RemoteEndpoints
    - source: salt://mgmt/remotevm/files/qubesair.RemoteEndpoints
    - user: root
    - group: root
    - mode: '0755'

{% endif %}
{% endif %}
{% endif %}
