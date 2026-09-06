"""Tests locaux sans réseau : ordre des règles livrées et erreurs de la recette.

    python3 -m unittest discover -s lab/tests -v

Le modèle ci-dessous teste les règles IPv4 du dépôt, pas le compilateur Proxmox.
"""
import ipaddress
from pathlib import Path
import re
import shlex
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
TF = ROOT / "lab/terraform/03-sdn-troisieme-lan/cluster-fw.tf"
EXAMPLES = ROOT / "lab/firewall/standalone"
ALIASES = {
    "lan_salle": "172.30.30.0/24", "+management": "172.30.30.0/24",
    "net_internal": "10.10.10.0/24", "net_dmz": "10.10.20.0/24",
    "net_services": "10.10.30.0/24", "net_evpn": "10.60.0.0/16",
}
for name, subnet in (("vint", 10), ("vdmz", 20), ("vsrv", 30)):
    ALIASES[f"+sdn/{name}-all"] = f"10.10.{subnet}.0/24"
    ALIASES[f"+sdn/{name}-gateway"] = f"10.10.{subnet}.1/32"


def objects(text):
    return [dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', line))
            for line in text.splitlines() if "{" in line and '"' in line]


def ini_rules(path, direction="FORWARD"):
    rules = []
    in_rules = False
    for line in path.read_text().splitlines():
        if line.startswith("["):
            in_rules = line == "[RULES]"
        tokens = shlex.split(line, comments=True)
        if not in_rules or not tokens or tokens[0] != direction:
            continue
        rule = {"action": tokens[1]}
        for key, value in zip(tokens[2::2], tokens[3::2]):
            rule[{"-p": "proto"}.get(key, key.lstrip("-"))] = value
        rules.append(rule)
    return rules


def verdict(rules, src, dst, port=22, proto="tcp"):
    for rule in rules:
        if any(key in rule and ipaddress.ip_address(ip) not in
               ipaddress.ip_network(ALIASES.get(rule[key], rule[key]))
               for key, ip in (("source", src), ("dest", dst))):
            continue
        if rule.get("proto", proto) != proto:
            continue
        if "dport" in rule:
            bounds = [int(p) for p in rule["dport"].split(":")]
            if not bounds[0] <= port <= bounds[-1]:
                continue
        return rule["action"]
    return "DROP"


class MatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = TF.read_text()
        cls.matrix = objects(source.split("  fw_matrix = [", 1)[1].split("\n  ]", 1)[0])
        cls.base = ini_rules(EXAMPLES / "cluster.fw.example")
        flows = objects(source.split("  fw_lan_to_nets = {", 1)[1].split("\n  }", 1)[0])
        cls.tf = []
        for dest in ("net_internal", "net_dmz", "net_services"):
            for flow in flows:
                cls.tf.append(dict(flow, action="ACCEPT", source="lan_salle", dest=dest))
        cls.tf.extend(cls.matrix)

    def test_ssh_lan_all_subnets(self):
        for rules in (self.base, self.tf):
            for last in (1, 40, 254):
                for subnet in (10, 20, 30):
                    with self.subTest(source=last, subnet=subnet):
                        self.assertEqual(verdict(rules, f"172.30.30.{last}", f"10.10.{subnet}.101"), "ACCEPT")

    def test_ssh_lan_host(self):
        self.assertEqual(verdict(ini_rules(EXAMPLES / "cluster.fw.example", "IN"),
                                 "172.30.30.40", "172.30.30.151"), "ACCEPT")

    def test_interzone_exact_tcp_matrix(self):
        expected = {(10, 20): {22, 80, 443}, (20, 10): set(),
                    (10, 30): {22, 3000, 9090}, (30, 10): {22, 9100},
                    (30, 20): {9100}, (20, 30): set()}
        for (src, dst), allowed in expected.items():
            for port in (22, 53, 80, 443, 3000, 3306, 5432, 8080, 9090, 9100):
                with self.subTest(src=src, dst=dst, port=port):
                    self.assertEqual(verdict(self.tf, f"10.10.{src}.101", f"10.10.{dst}.101", port),
                                     "ACCEPT" if port in allowed else "DROP")

    def test_base_interzone(self):
        self.assertEqual(verdict(self.base, "10.10.10.100", "10.10.20.101", 443), "ACCEPT")
        self.assertEqual(verdict(self.base, "10.10.10.100", "10.10.20.101", 8080), "DROP")
        self.assertEqual(verdict(self.base, "10.10.20.101", "10.10.10.100", 5432), "DROP")
        self.assertEqual(verdict(self.base, "10.10.10.100", "10.10.30.101", 80), "DROP")

    def test_egress_dns_and_web(self):
        for rules in (self.base, self.tf):
            for proto in ("tcp", "udp"):
                self.assertEqual(verdict(rules, "10.10.20.101", "1.1.1.1", 53, proto), "ACCEPT")
            self.assertEqual(verdict(rules, "10.10.20.101", "1.1.1.1", 443), "ACCEPT")
            self.assertEqual(verdict(rules, "10.10.20.101", "1.1.1.1", 22), "DROP")
        self.assertEqual(verdict(self.tf, "10.10.30.101", "1.1.1.1", 53), "ACCEPT")

    def test_vnet_host_origin_and_intra_dmz(self):
        for vnet, subnet in (("vint", 10), ("vdmz", 20), ("vsrv", 30)):
            rules = ini_rules(EXAMPLES / f"{vnet}.fw.example")
            self.assertEqual(verdict(rules, "172.30.30.151", f"10.10.{subnet}.101"), "ACCEPT")
            self.assertEqual(verdict(rules, "0.0.0.0", "255.255.255.255", 67, "udp"), "ACCEPT")
            self.assertEqual(verdict(rules, f"10.10.{subnet}.101", f"10.10.{subnet}.1", 53), "ACCEPT")
        dmz = ini_rules(EXAMPLES / "vdmz.fw.example")
        self.assertEqual(verdict(dmz, "10.10.20.101", "10.10.20.102", 80), "ACCEPT")
        self.assertEqual(verdict(dmz, "10.10.20.101", "10.10.20.102", 22), "DROP")

    def test_no_future_ipsets_in_tp09_vnets(self):
        for vnet in ("vint", "vdmz"):
            text = (EXAMPLES / f"{vnet}.fw.example").read_text()
            self.assertNotIn("+sdn/vsrv", text)
            self.assertNotIn("+sdn/vprod", text)

    def test_documented_guests_keep_lan_ssh(self):
        doc = (ROOT / "09-firewall-inter-zones.md").read_text()
        for vmid in (101, 102, 111):
            block = doc.split(f"cat > /etc/pve/firewall/{vmid}.fw <<'EOF'", 1)[1].split("\nEOF", 1)[0]
            self.assertIn("IN ACCEPT -source lan_salle -p tcp -dport 22", block)

    def test_templates_match_standalone_examples(self):
        template = ROOT / "lab/terraform/03-sdn-troisieme-lan/templates/vsrv.fw.tftpl"
        self.assertEqual(ini_rules(template), ini_rules(EXAMPLES / "vsrv.fw.example"))


# Command stubs inherited by the child Bash. No network connections or temp files.
MOCK = r'''
ip() {
  if [[ "$*" == *"route get"* ]]; then echo "via 172.30.30.151 src 172.30.30.40";
  else echo "2: eth0 inet 172.30.30.40/24 brd 172.30.30.255"; fi
}
nc() { return 0; }
ssh() {
  while [[ $1 == -o ]]; do shift 2; done
  local target=$1; shift
  [[ $SCENARIO == ssh_down && $target == root@10.10.20.101 ]] && return 255
  [[ $SCENARIO == missing_tool && "$*" == *"command -v"* ]] && return 127
  if [[ $1 == nc ]]; then
    local port=${!#} dest=${@: -2:1}
    [[ $SCENARIO == missing_listener && $port == 8080 && $target == root@10.10.20.101 ]] && return 1
    if [[ $target == eleve@10.10.10.100 && $dest == 10.10.20.101 && $port == 8080 ||
          $target == root@10.10.20.101 && $dest == 10.10.10.100 ||
          $target == eleve@10.10.30.101 && $dest == 10.10.10.100 && $port == 5432 ||
          $target == eleve@10.10.30.101 && $dest == 10.10.20.101 && $port == 80 ||
          $target == eleve@10.10.10.100 && $dest == 10.10.30.101 && $port == 8080 ||
          $target == root@10.10.20.101 && $dest == 10.10.30.101 && $port == 22 ]]; then
      [[ $SCENARIO == connection_lost ]] && return 255
      [[ $SCENARIO == leak ]] && return 0
      return 1
    fi
  fi
  return 0
}
export -f ip nc ssh
export SCENARIO
bash lab/scripts/test-firewall-standalone.sh --int 10.10.10.100 --dmz 10.10.20.101 "$@"
'''


class RecipeTests(unittest.TestCase):
    def test_services_scenarios(self):
        for scenario, code in (("healthy", 0), ("leak", 1), ("connection_lost", 1)):
            with self.subTest(scenario=scenario):
                result = subprocess.run(["bash", "-c", f"SCENARIO={scenario}\n" + MOCK,
                                         "mock", "--services", "10.10.30.101", "--exporter", "10.10.10.110"],
                                        cwd=ROOT, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_mock_scenarios(self):
        for scenario, code in (("healthy", 0), ("ssh_down", 2), ("missing_tool", 2),
                               ("missing_listener", 2), ("connection_lost", 1), ("leak", 1)):
            with self.subTest(scenario=scenario):
                result = subprocess.run(["bash", "-c", f"SCENARIO={scenario}\n" + MOCK],
                                        cwd=ROOT, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_missing_argument(self):
        result = subprocess.run(["bash", "lab/scripts/test-firewall-standalone.sh", "--int"],
                                cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
