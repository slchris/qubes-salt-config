#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "salt" / "templates" / "http-proxy-net"
SCRIPT = UNIT / "files" / "http-proxy-net-start.sh"


def render(name, nodename):
    from jinja2 import Environment, FileSystemLoader

    env = Environment(loader=FileSystemLoader(str(ROOT / "salt")))
    return env.get_template(name).render(grains={"nodename": nodename})


class ConfigTest(unittest.TestCase):
    def test_config_renders_http_proxy_nets(self):
        from jinja2 import Environment, FileSystemLoader

        env = Environment(loader=FileSystemLoader(str(ROOT / "salt")))
        cfg = env.get_template("config.jinja").module.cfg
        self.assertEqual(cfg["http_proxy_nets"], {"http-proxy": {}})


class InstallTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sls = render("templates/http-proxy-net/install.sls", "tpl-http-proxy-net")

    def test_base_table_is_fail_closed(self):
        self.assertEqual(self.sls.count("policy drop;"), 2)
        self.assertIn("iifname \"vif*\" meta nfproto ipv4 tcp counter redirect to :12345", self.sls)
        self.assertIn("udp dport 53 counter redirect to :53", self.sls)
        self.assertIn("jump output-dynamic", self.sls)
        self.assertIn("jump bootstrap", self.sls)

    def test_redirected_sockets_are_accepted(self):
        for spec in ("udp dport 53 accept", "tcp dport 53 accept", "tcp dport 12345 accept"):
            self.assertIn('iifname "vif*" meta nfproto ipv4 ' + spec, self.sls)

    def test_daemons_start_after_ready_without_a_cycle(self):
        self.assertIn("ConditionPathExists=/run/http-proxy-net/ready", self.sls)
        self.assertIn("ExecStart=/usr/bin/http-proxy-net-start --prepare", self.sls)
        self.assertNotIn("Requires=http-proxy-net-start.service", self.sls)
        self.assertNotIn("/rw/config/rc.local", self.sls)

    def test_start_script_is_not_rendered_as_jinja(self):
        # file.managed copies `source` verbatim only when `template` is unset;
        # setting any renderer would turn the script's ${#...} into a Jinja
        # comment. Keep the state template-free and keep the script free of
        # Jinja delimiters so a future edit cannot break the copy.
        start_state = self.sls.split('"tpl-http-proxy-net-start-script":', 1)[1]
        start_state = start_state.split('"tpl-http-proxy-net-fail-closed-unit":', 1)[0]
        self.assertNotIn("- template:", start_state)
        self.assertNotIn("{%", SCRIPT.read_text())
        self.assertNotIn("{{", SCRIPT.read_text())
        self.assertNotIn("{#", SCRIPT.read_text())

    def test_packaged_units_are_masked(self):
        for unit in (
            "tinyproxy.service",
            "redsocks.service",
            "dnscrypt-proxy.service",
            "dnscrypt-proxy.socket",
            "dnscrypt-proxy-resolvconf.service",
        ):
            self.assertIn(unit, self.sls)

    def test_dnscrypt_uses_static_doh_only(self):
        self.assertIn("[static.cloudflare]", self.sls)
        self.assertIn("[static.google]", self.sls)
        self.assertNotIn("[sources]", self.sls)
        self.assertIn("http_proxy = 'http://127.0.0.1:8888'", self.sls)

    def test_redsocks_is_static_and_local(self):
        conf = (UNIT / "install.sls").read_text()
        self.assertIn("local_ip = 0.0.0.0", conf)
        self.assertIn("local_port = 12345", conf)
        self.assertIn("type = http-connect", conf)
        self.assertIn("on_proxy_fail = close", conf)


class ConfigureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sls = render("templates/http-proxy-net/configure.sls", "sys-http-proxy")

    def test_firewall_block_reloads_base_then_rules(self):
        self.assertIn("# >>> http-proxy-net >>>", self.sls)
        self.assertIn("nft -f /etc/http-proxy-net/base.nft", self.sls)
        self.assertIn("/usr/bin/http-proxy-net-start --rules", self.sls)
        self.assertNotIn("rc.local", self.sls)

    def test_upstream_conf_is_never_overwritten(self):
        self.assertIn("/rw/config/http-proxy-net/upstream.conf", self.sls)
        self.assertIn("- replace: False", self.sls)
        self.assertIn("- mode: '0600'", self.sls)


class CheckModeTest(unittest.TestCase):
    def run_check(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "upstream.conf"
            if text is not None:
                conf.write_text(text)
            env = dict(os.environ, UPSTREAM_CONF=str(conf))
            return subprocess.run(
                ["sh", str(SCRIPT), "--check"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode

    def test_missing_skeleton_and_valid_conf(self):
        self.assertEqual(self.run_check(None), 0)
        self.assertEqual(self.run_check("#PROXY_HOST=\n#PROXY_PORT=\n"), 0)
        self.assertEqual(
            self.run_check(
                "PROXY_HOST=proxy.example.net\n"
                "PROXY_PORT=8080\n"
                "PROXY_USER=alice\n"
                "PROXY_PASS=s3cret!\n"
            ),
            0,
        )

    def test_reserved_credential_characters_are_rejected(self):
        base = (
            "PROXY_HOST=proxy.example.net\n"
            "PROXY_PORT=8080\n"
            "PROXY_USER=alice\n"
            "PROXY_PASS=s3cret!\n"
        )
        self.assertNotEqual(self.run_check(base.replace("alice", "a:b")), 0)
        self.assertNotEqual(self.run_check(base.replace("s3cret!", "a@b")), 0)
        self.assertNotEqual(self.run_check(base.replace("s3cret!", "a b")), 0)

    def test_bad_numbers_and_ports_are_rejected(self):
        base = (
            "PROXY_HOST=proxy.example.net\n"
            "PROXY_PORT=8080\n"
            "PROXY_USER=alice\n"
            "PROXY_PASS=s3cret!\n"
        )
        self.assertNotEqual(self.run_check(base.replace("8080", "0")), 0)
        self.assertNotEqual(self.run_check(base.replace("8080", "70000")), 0)
        self.assertNotEqual(self.run_check(base + "CONNECT_PORTS=80\n"), 0)
        self.assertNotEqual(self.run_check(base + "CONNECT_PORTS=443,http\n"), 0)
        self.assertEqual(self.run_check(base + "CONNECT_PORTS=80,443\n"), 0)

    def test_bad_host_is_rejected(self):
        base = (
            "PROXY_HOST=proxy.example.net\n"
            "PROXY_PORT=8080\n"
            "PROXY_USER=alice\n"
            "PROXY_PASS=s3cret!\n"
        )
        for host in ("-proxy.example.net", "proxy example.net", "proxy/../x"):
            self.assertNotEqual(
                self.run_check(base.replace("proxy.example.net", host)), 0
            )


if __name__ == "__main__":
    unittest.main()
