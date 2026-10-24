{# SPDX-License-Identifier: MIT #}
{%- from 'config.jinja' import cfg with context -%}
{%- from 'qubesair/macros/artifacts.jinja' import stage -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set rv = cfg.get('remotevm', {}) -%}
{%- set csr = rv.get('grpc', {}).get('csr', {}) -%}
{%- set node = grains['nodename'] -%}
{%- set console = qa.get('enabled', False) and node == qa.get('qube', 'qubesair-console') -%}
{%- set issuer = csr.get('enabled', False) and node == csr.get('console_qube', 'qubesair-console') -%}
{%- set relay = csr.get('enabled', False) and node == rv.get('relay', 'mgmt-jump') -%}

{% if node != 'dom0' and (console or issuer or relay) %}
include:
  - qubesair.artifact-fetch

{% if console %}
{{ stage('console', qa.get('console_binary_source', 'salt://qubesair/files/qubes-air-console'), qa.get('console_binary_sha256', ''), []) }}
{% if qa.get('console_web_source') %}
{{ stage('web', qa.console_web_source, qa.get('console_web_sha256', ''), []) }}
{% endif %}
{% if qa.get('backup', {}).get('enabled', False) %}
{% set backup = qa.backup %}
{{ stage('backup', backup.get('binary_source', 'salt://qubesair/files/qubes-air-backup'), backup.get('binary_sha256', ''), []) }}
{% endif %}
{% endif %}

{% if issuer %}
{{ stage('issuer', csr.get('issue_bin_source', ''), csr.get('issue_bin_sha256', ''), []) }}
{{ stage('endpoints', csr.get('list_endpoints_source', ''), csr.get('list_endpoints_sha256', ''), []) }}
{% endif %}

{% if relay %}
{{ stage('relay-call', csr.get('relay_call_source', ''), csr.get('relay_call_sha256', ''), []) }}
{{ stage('relay-bootstrap', csr.get('relay_bootstrap_source', ''), csr.get('relay_bootstrap_sha256', ''), []) }}
{% endif %}
{% else %}
"qubesair-artifact-prefetch-target-required":
  test.fail_without_changes:
    - name: Artifact prefetch requires an enabled Console, issuer or Relay target.
    - failhard: True
{% endif %}
