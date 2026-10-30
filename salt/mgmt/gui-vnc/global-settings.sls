{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Read-only Admin API grants for qubes-global-config in the GUI domain
(runs IN dom0).

This removes the first wave of Request refused errors, but it does NOT make
Global Settings fully usable in a GUI domain: the app also calls dom0-only
policy admin services (policy.Get on 50-config-*) and qubes-hcl-report, which
are absent there. Use Qubes Manager for per-qube actions and run Global
Settings in dom0. See the README section "Global Settings is a dom0 app".

qubes-global-config's DeviceManager iterates every qube and calls
admin.vm.device.<class>.Available and .Assigned, while the USB page calls
pci.Attached. Its Basics/Updates pages read properties and features. The
GUI-domain policy (mgmt.gui-vnc.create) only granted pci/mic.Available on
dom0, so the app died at startup with:

  qubesadmin.exc.QubesDaemonAccessError: Service call error: Request refused
  at qubes_config/global_config/usb_devices.py: ... get_attached_devices()

This state is deliberately separate from create: it widens the GUI domain's
read visibility to every qube and to dom0.

Two policy details matter here:

  * The Admin API request is sent to dom0 (qubesd). The policy target column
    names the administered VM, and every non-dom0 line carries `target=dom0`
    to route the request to qubesd. The create policy uses the same shape for
    admin.vm.List.
  * `@anyvm` is not expanded as an Admin API *target* on R4.3, so the lines
    spell out the concrete VM classes
    (@type:AppVM/TemplateVM/DispVM/StandaloneVM). dom0 is the AdminVM and has
    its own explicit lines.

The set includes property.GetAll (the Basic handler reads all dom0
properties), tag.Get/List (the update handler's Whonix checks) and
feature.Get/List, plus the device Available/Assigned/Attached methods. It
grants no write methods (Assign/Set/Unassign/Remove), so the app can display
device state but cannot reassign devices; those operations still get Request
refused and must be done from dom0.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.global-settings

Remove the file (or apply the state with gui_vnc.enabled False) to revoke it.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) %}

"gui-vnc-global-settings-policy":
  file.managed:
    - name: /etc/qubes/policy.d/51-gui-global-settings.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.global-settings. READ-ONLY grants only:
        # no device/property/feature writes are allowed.
        # The Admin API request is sent to dom0 (qubesd); the target column
        # names the administered VM and `target=dom0` routes the request. The
        # create policy uses the same shape for admin.vm.List. Without
        # target=dom0 these lines do not match the dom0 qrexec destination.
        # @type: covers qubes created after this state runs, and the source
        # GUI domain itself (an AppVM).
        {% for target in ['@type:AppVM', '@type:TemplateVM', '@type:DispVM', '@type:StandaloneVM'] %}
        admin.vm.device.block.Available  *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.block.Assigned   *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.mic.Available    *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.mic.Assigned     *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.pci.Available    *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.pci.Assigned     *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.pci.Attached     *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.usb.Available    *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.usb.Assigned     *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.device.usb.Attached     *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.property.Get            *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.property.GetAll         *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.property.List           *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.volume.List             *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.volume.Info             *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.CurrentState            *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.feature.Get             *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.feature.List            *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.tag.Get                 *   {{ qube }}  {{ target }}  allow  target=dom0
        admin.vm.tag.List                *   {{ qube }}  {{ target }}  allow  target=dom0
        {% endfor %}

        # dom0 is the AdminVM: @anyvm and @type: do not cover it, so grant the
        # same read-only set for the explicit dom0 target.
        admin.vm.device.block.Available  *   {{ qube }}  dom0  allow
        admin.vm.device.block.Assigned   *   {{ qube }}  dom0  allow
        admin.vm.device.mic.Available    *   {{ qube }}  dom0  allow
        admin.vm.device.mic.Assigned     *   {{ qube }}  dom0  allow
        admin.vm.device.pci.Available    *   {{ qube }}  dom0  allow
        admin.vm.device.pci.Assigned     *   {{ qube }}  dom0  allow
        admin.vm.device.pci.Attached     *   {{ qube }}  dom0  allow
        admin.vm.device.usb.Available    *   {{ qube }}  dom0  allow
        admin.vm.device.usb.Assigned     *   {{ qube }}  dom0  allow
        admin.vm.device.usb.Attached     *   {{ qube }}  dom0  allow
        admin.vm.property.Get            *   {{ qube }}  dom0  allow
        admin.vm.property.GetAll         *   {{ qube }}  dom0  allow
        admin.vm.property.List           *   {{ qube }}  dom0  allow
        admin.vm.volume.List             *   {{ qube }}  dom0  allow
        admin.vm.volume.Info             *   {{ qube }}  dom0  allow
        admin.vm.CurrentState            *   {{ qube }}  dom0  allow
        admin.vm.feature.Get             *   {{ qube }}  dom0  allow
        admin.vm.feature.List            *   {{ qube }}  dom0  allow
        admin.vm.tag.Get                 *   {{ qube }}  dom0  allow
        admin.vm.tag.List                *   {{ qube }}  dom0  allow

        # The Global Settings clipboard/file/split-GPG pages use the Qubes
        # policy admin client (qrexec policy.* services) to read dom0's policy
        # files. These are normal qrexec services, not admin.* methods.
        policy.List                      *   {{ qube }}  dom0  allow
        policy.Get                       *   {{ qube }}  dom0  allow
        policy.GetFiles                  *   {{ qube }}  dom0  allow
        policy.include.List              *   {{ qube }}  dom0  allow
        policy.include.Get               *   {{ qube }}  dom0  allow

{% else %}

"gui-vnc-global-settings-policy-absent":
  file.absent:
    - name: /etc/qubes/policy.d/51-gui-global-settings.policy

"gui-vnc-global-settings-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.global-settings: cfg.gui_vnc.enabled is False — removed the
        read-only policy for {{ qube }}.

{% endif %}
{% endif %}
