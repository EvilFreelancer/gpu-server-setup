"""Run scripts/arc-power-cap.sh against a fake sysfs tree, never real hardware."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/arc-power-cap.sh"


class ArcPowerCapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sys = Path(self.tmp.name) / "sys"
        self.conf = Path(self.tmp.name) / "arc-power-cap"
        self.conf.write_text("")

    def device(self, bdf, vendor, device, hwmon=None, files=None, card=None):
        d = self.sys / "bus/pci/devices" / bdf
        d.mkdir(parents=True)
        (d / "vendor").write_text(vendor + "\n")
        (d / "device").write_text(device + "\n")
        if hwmon:
            h = d / "hwmon/hwmon7"
            h.mkdir(parents=True)
            (h / "name").write_text(hwmon + "\n")
            for name, value in (files or {}).items():
                (h / name).write_text(value + "\n")
        if card:
            c = d / "drm" / card
            c.mkdir(parents=True)
            (c / "gt_max_freq_mhz").write_text("2400\n")
            (c / "gt_boost_freq_mhz").write_text("2400\n")
        return d

    def run_cap(self, **conf):
        self.conf.write_text("".join(f'{k}="{v}"\n' for k, v in conf.items()))
        env = dict(os.environ, SYS=str(self.sys), ARC_CONF=str(self.conf), ARC_WAIT_S="1")
        return subprocess.run(["sh", str(SCRIPT)], env=env, text=True,
                              capture_output=True, timeout=10)

    def read(self, path):
        return (self.sys / "bus/pci/devices" / path).read_text().strip()

    def test_caps_every_matching_i915_card(self):
        for bdf in ("0000:05:00.0", "0000:0a:00.0"):
            self.device(bdf, "0x8086", "0x56a0", "i915", {"power1_max": "210000000"})
        result = self.run_cap(ARC_PL1_W=170)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read("0000:05:00.0/hwmon/hwmon7/power1_max"), "170000000")
        self.assertEqual(self.read("0000:0a:00.0/hwmon/hwmon7/power1_max"), "170000000")
        self.assertIn("readback 170 W", result.stdout)

    def test_ignores_other_vendors_and_ids(self):
        self.device("0000:05:00.0", "0x8086", "0x56a0", "i915", {"power1_max": "210000000"})
        nvidia = self.device("0000:01:00.0", "0x10de", "0x2684", "nvidia", {"power1_max": "1"})
        self.device("0000:00:02.0", "0x8086", "0x4680")                # iGPU, no hwmon
        result = self.run_cap(ARC_PL1_W=150)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((nvidia / "hwmon/hwmon7/power1_max").read_text().strip(), "1")
        self.assertNotIn("0000:00:02.0", result.stdout + result.stderr)

    def test_xe_package_limit_when_power1_is_absent(self):
        self.device("0000:03:00.0", "0x8086", "0x56a0", "xe", {"power2_max": "190000000"})
        result = self.run_cap(ARC_PL1_W=160)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read("0000:03:00.0/hwmon/hwmon7/power2_max"), "160000000")

    def test_clock_cap_sets_max_and_boost(self):
        self.device("0000:05:00.0", "0x8086", "0x56a0", "i915",
                    {"power1_max": "210000000"}, card="card0")
        result = self.run_cap(ARC_PL1_W=170, ARC_MAX_MHZ=2000)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read("0000:05:00.0/drm/card0/gt_max_freq_mhz"), "2000")
        self.assertEqual(self.read("0000:05:00.0/drm/card0/gt_boost_freq_mhz"), "2000")

    def test_no_matching_card_fails(self):
        self.device("0000:05:00.0", "0x8086", "0x56a0", "i915", {"power1_max": "210000000"})
        result = self.run_cap(ARC_IDS="0xe20b", ARC_PL1_W=170)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no PCI devices", result.stderr)

    def test_card_without_hwmon_fails(self):
        self.device("0000:05:00.0", "0x8086", "0x56a0")
        result = self.run_cap(ARC_PL1_W=170)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no i915/xe hwmon", result.stderr)


if __name__ == "__main__":
    unittest.main()
