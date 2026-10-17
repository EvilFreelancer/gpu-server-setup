"""Run scripts/arc-aspm.sh against a fake sysfs tree, never real hardware."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/arc-aspm.sh"

# Real topology of an AMD B550 host with two A770: card 1 on a CPU root port,
# card 0 behind the chipset, a Realtek NIC behind the chipset too.
TOPOLOGY = {
    # bdf: (sysfs path below /sys/devices, vendor, device, link attrs)
    "0000:00:03.1": ("pci0000:00/0000:00:03.1", "0x1022", "0x1483", []),
    "0000:08:00.0": ("pci0000:00/0000:00:03.1/0000:08:00.0", "0x8086", "0x4fa0",
                     ["l1_aspm", "l1_1_aspm", "l1_1_pcipm"]),
    "0000:09:01.0": ("pci0000:00/0000:00:03.1/0000:08:00.0/0000:09:01.0", "0x8086", "0x4fa4", []),
    "0000:0a:00.0": ("pci0000:00/0000:00:03.1/0000:08:00.0/0000:09:01.0/0000:0a:00.0",
                     "0x8086", "0x56a0", ["l1_aspm"]),
    "0000:09:04.0": ("pci0000:00/0000:00:03.1/0000:08:00.0/0000:09:04.0", "0x8086", "0x4fa4", []),
    "0000:0b:00.0": ("pci0000:00/0000:00:03.1/0000:08:00.0/0000:09:04.0/0000:0b:00.0",
                     "0x8086", "0x4f90", ["l1_aspm"]),
    "0000:02:00.0": ("pci0000:00/0000:00:01.2/0000:01:00.2/0000:02:00.0", "0x1022", "0x43ea", []),
    "0000:03:00.0": ("pci0000:00/0000:00:01.2/0000:01:00.2/0000:02:00.0/0000:03:00.0",
                     "0x8086", "0x4fa0", ["l1_aspm"]),
    "0000:04:01.0": ("pci0000:00/0000:00:01.2/0000:01:00.2/0000:02:00.0/0000:03:00.0/0000:04:01.0",
                     "0x8086", "0x4fa4", []),
    "0000:05:00.0": ("pci0000:00/0000:00:01.2/0000:01:00.2/0000:02:00.0/0000:03:00.0/0000:04:01.0/0000:05:00.0",
                     "0x8086", "0x56a0", ["l1_aspm"]),
    "0000:07:00.0": ("pci0000:00/0000:00:01.2/0000:01:00.2/0000:02:09.0/0000:07:00.0",
                     "0x10ec", "0x8168", ["l1_aspm", "clkpm"]),
}


class ArcAspmTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sys = Path(self.tmp.name) / "sys"
        conf = Path(self.tmp.name) / "arc-aspm"
        conf.write_text("")
        self.env = dict(os.environ, SYS=str(self.sys), ARC_CONF=str(conf))
        devices = self.sys / "bus/pci/devices"
        devices.mkdir(parents=True)
        for bdf, (path, vendor, device, attrs) in TOPOLOGY.items():
            d = self.sys / "devices" / path
            d.mkdir(parents=True, exist_ok=True)
            (d / "vendor").write_text(vendor + "\n")
            (d / "device").write_text(device + "\n")
            (d / "config").write_bytes(bytes.fromhex(vendor[4:6] + vendor[2:4]) + b"\0" * 62)
            if attrs:
                (d / "link").mkdir()
                for a in attrs:
                    (d / "link" / a).write_text("0\n" if a != "l1_1_aspm" else "1\n")
            (devices / bdf).symlink_to(d)
        policy = self.sys / "module/pcie_aspm/parameters"
        policy.mkdir(parents=True)
        (policy / "policy").write_text("[default] performance powersave powersupersave\n")

    def run_aspm(self):
        return subprocess.run(["sh", str(SCRIPT)], env=self.env, text=True,
                              capture_output=True, timeout=10)

    def attr(self, bdf, name):
        return (self.sys / "bus/pci/devices" / bdf / name).read_text().strip()

    def test_policy_and_audio_removal(self):
        result = self.run_aspm()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        policy = self.sys / "module/pcie_aspm/parameters/policy"
        self.assertEqual(policy.read_text().strip(), "powersupersave")
        self.assertEqual(self.attr("0000:0b:00.0", "remove"), "1")
        self.assertIn("removing Arc audio function 0000:0b:00.0", result.stdout)

    def test_non_arc_links_are_fenced_off(self):
        self.run_aspm()
        self.assertEqual(self.attr("0000:07:00.0", "link/l1_aspm"), "0")
        self.assertEqual(self.attr("0000:07:00.0", "link/clkpm"), "0")

    def test_substates_are_disabled_on_arc_links(self):
        self.run_aspm()
        self.assertEqual(self.attr("0000:08:00.0", "link/l1_1_aspm"), "0")
        self.assertEqual(self.attr("0000:08:00.0", "link/l1_1_pcipm"), "0")

    def test_arc_chain_reported_and_not_disabled(self):
        result = self.run_aspm()
        for bdf in ("0000:08:00.0", "0000:0a:00.0", "0000:03:00.0", "0000:05:00.0"):
            self.assertIn("arc-aspm: " + bdf + " l1_aspm=", result.stdout)
        self.assertNotIn("0000:07:00.0 l1_aspm", result.stdout)
        self.assertNotIn("0000:02:00.0", result.stdout)

    def test_lost_card_fails(self):
        (self.sys / "bus/pci/devices/0000:08:00.0/config").write_bytes(b"\xff" * 64)
        result = self.run_aspm()
        self.assertEqual(result.returncode, 1)
        self.assertIn("0000:08:00.0 does not answer config reads", result.stderr)

    def test_no_arc_gpu_fails_without_touching_policy(self):
        self.env["ARC_CONF"] = str(Path(self.tmp.name) / "conf2")
        Path(self.env["ARC_CONF"]).write_text('ARC_IDS="0xe20b"\n')
        result = self.run_aspm()
        self.assertEqual(result.returncode, 1)
        self.assertIn("default", (self.sys / "module/pcie_aspm/parameters/policy").read_text())


if __name__ == "__main__":
    unittest.main()
