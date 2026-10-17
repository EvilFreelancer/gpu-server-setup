"""Run the real checker against isolated command fixtures, never real Docker/GPU."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
KERNEL = "6.12.107+deb13-amd64"
NEXT_KERNEL = "6.12.111+deb13-amd64"

STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

case = json.loads(os.environ["GPU_CHECK_FIXTURE"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "uname":
    print(case["kernel"])
elif name == "lspci":
    if case.get("gpu", True):
        print("01:00.0 VGA compatible controller: NVIDIA Corporation GPU")
elif name == "nvidia-smi":
    if not case.get("gpu", True):
        sys.exit(1)
    if "-L" in args:
        print("GPU 0: NVIDIA Test GPU (UUID: GPU-test)")
    elif any("driver_version" in arg for arg in args):
        print("610.57.04")
elif name == "nvcc":
    print("Cuda compilation tools, release 13.3, V13.3.0")
elif name == "docker":
    if args == ["--version"]:
        print("Docker version fixture")
    elif args == ["info"]:
        print("Runtimes: io.containerd.runc.v2 nvidia runc")
    elif args and args[0] == "run":
        print("GPU 0: NVIDIA Test GPU (UUID: GPU-test)")
elif name == "dpkg-query":
    package = args[-1]
    if package == "linux-image-*":
        if case.get("image_query_error"):
            print("fixture: package database unavailable", file=sys.stderr)
            sys.exit(2)
        for status, package in case["images"]:
            print(status, package)
    else:
        status = case["metas"].get(package)
        if status is None:
            sys.exit(1)
        print(status, end="")
elif name == "readlink":
    path = args[-1]
    if any(path == "/lib/modules/" + k + "/build/Makefile" for k in case["headers"]):
        print(path)
    else:
        sys.exit(1)
elif name == "modinfo":
    kernel = args[args.index("-k") + 1]
    if kernel in case["modules"]:
        print("/lib/modules/" + kernel + "/updates/dkms/nvidia.ko.xz")
    else:
        print("modinfo: ERROR: Module nvidia not found.", file=sys.stderr)
        sys.exit(1)
else:
    raise SystemExit("Unexpected fixture command: " + name)
'''


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        stub = self.bin / "fixture"
        stub.write_text(STUB)
        stub.chmod(0o755)
        for name in ("uname", "lspci", "nvidia-smi", "nvcc", "docker",
                     "dpkg-query", "readlink", "modinfo"):
            (self.bin / name).symlink_to(stub)
        self.case = {
            "kernel": KERNEL,
            "images": [("installed", "linux-image-amd64"),
                       ("installed", "linux-image-" + KERNEL)],
            "metas": {"linux-headers-amd64": "installed"},
            "headers": [KERNEL],
            "modules": [KERNEL],
        }

    def run_check(self, *args):
        env = dict(os.environ, GPU_CHECK_FIXTURE=json.dumps(self.case))
        env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
        return subprocess.run(
            ["bash", str(ROOT / "scripts/check.sh"), *args], env=env,
            text=True, capture_output=True, timeout=10,
        )

    def assert_failure(self, message):
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stdout)
        self.assertNotIn("All checks passed.", result.stdout)

    def add_next_kernel(self):
        self.case["images"].append(("installed", "linux-image-" + NEXT_KERNEL))

    def test_prepared_debian_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All checks passed.", result.stdout)

    def test_missing_tracking_metapackage_fails_with_working_gpu(self):
        self.case["metas"].clear()
        self.assert_failure("linux-headers-amd64")

    def test_removed_metapackage_does_not_count_as_installed(self):
        self.case["metas"]["linux-headers-amd64"] = "config-files"
        self.assert_failure("linux-headers-amd64")

    def test_missing_running_headers_fails_with_working_gpu(self):
        self.case["headers"].clear()
        self.assert_failure("headers missing for " + KERNEL)

    def test_missing_running_module_fails_with_working_gpu(self):
        self.case["modules"].clear()
        self.assert_failure("NVIDIA module missing for " + KERNEL)

    def test_new_kernel_without_headers_fails_before_reboot(self):
        self.add_next_kernel()
        self.assert_failure("headers missing for " + NEXT_KERNEL)

    def test_new_kernel_without_nvidia_module_fails_before_reboot(self):
        self.add_next_kernel()
        self.case["headers"].append(NEXT_KERNEL)
        self.assert_failure("NVIDIA module missing for " + NEXT_KERNEL)

    def test_prepared_next_kernel_passes(self):
        self.add_next_kernel()
        self.case["headers"].append(NEXT_KERNEL)
        self.case["modules"].append(NEXT_KERNEL)
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(NEXT_KERNEL, result.stdout)

    def test_removed_kernel_is_not_checked(self):
        self.case["images"].append(("config-files", "linux-image-" + NEXT_KERNEL))
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_package_query_error_fails_closed(self):
        self.case["image_query_error"] = True
        self.assert_failure("cannot list installed kernel images")

    def test_tracking_headers_required_without_image_metapackage(self):
        self.case["images"] = [("installed", "linux-image-" + KERNEL)]
        self.case["metas"].clear()
        self.assert_failure("linux-headers-amd64")

    def test_ubuntu_hwe_uses_matching_tracking_metapackage(self):
        kernel = "6.11.0-29-generic"
        self.case.update(
            kernel=kernel,
            images=[("installed", "linux-image-generic-hwe-24.04"),
                    ("installed", "linux-image-" + kernel)],
            metas={"linux-headers-generic-hwe-24.04": "installed"},
            headers=[kernel], modules=[kernel],
        )
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("linux-headers-generic-hwe-24.04", result.stdout)

    def test_debian_cloud_uses_matching_tracking_metapackage(self):
        kernel = "6.12.111+deb13-cloud-amd64"
        self.case.update(
            kernel=kernel,
            images=[("installed", "linux-image-cloud-amd64"),
                    ("installed", "linux-image-" + kernel)],
            metas={"linux-headers-cloud-amd64": "installed"},
            headers=[kernel], modules=[kernel],
        )
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("linux-headers-cloud-amd64", result.stdout)

    def test_ubuntu_hwe_without_image_meta_does_not_accept_ga_headers(self):
        kernel = "6.11.0-29-generic"
        self.case.update(
            kernel=kernel,
            images=[("installed", "linux-image-" + kernel)],
            metas={"linux-headers-generic": "installed"},
            headers=[kernel], modules=[kernel],
        )
        self.assert_failure("cannot determine headers tracking metapackage")

    def test_ubuntu_without_image_meta_stops_instead_of_guessing_headers(self):
        kernel = "6.11.0-29-generic"
        self.case.update(
            kernel=kernel,
            images=[("installed", "linux-image-" + kernel)],
            metas={"linux-headers-generic-hwe-24.04": "installed"},
            headers=[kernel], modules=[kernel],
        )
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot determine headers tracking metapackage", result.stdout)
        self.assertNotIn("metapackage missing: linux-headers-generic", result.stdout)

    def test_unsigned_ubuntu_kernel_is_checked(self):
        self.case["images"].append(("installed", "linux-image-unsigned-6.11.0-29-generic"))
        self.assert_failure("headers missing for 6.11.0-29-generic")

    def test_auxiliary_image_packages_are_not_treated_as_kernel_flavours(self):
        self.case["images"].extend([
            ("installed", "linux-image-extra-virtual"),
            ("installed", "linux-image-" + KERNEL + "-dbg"),
            ("installed", "linux-image-" + KERNEL + "-signed-template"),
        ])
        result = self.run_check("--no-docker-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_gpu_fails(self):
        self.case["gpu"] = False
        self.assert_failure("no NVIDIA GPUs visible")

    def test_help_does_not_run_checks(self):
        result = self.run_check("--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("=== Layer", result.stdout)


if __name__ == "__main__":
    unittest.main()
