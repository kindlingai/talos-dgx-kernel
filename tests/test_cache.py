import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fingerprint", ROOT / "scripts/kernel-fingerprint.py")
assert spec is not None and spec.loader is not None
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)


class CacheContract(unittest.TestCase):
    def test_module_only_edits_do_not_change_linux_fingerprint(self):
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp)
            for directory in ("scripts", "kernel", "extension", "talos", "dispram"):
                shutil.copytree(ROOT / directory, tree / directory)
            shutil.copy(ROOT / "Dockerfile", tree / "Dockerfile")
            config = "kernel/config"
            before = fp.fingerprint(tree, config)
            for name in ("scripts/build-nvidia.sh", "scripts/check-extension.sh", "scripts/build-dispram.sh", "extension/manifest.yaml", "talos/installer.yaml"):
                with (tree / name).open("a") as file:
                    file.write("\n# module-only change\n")
                self.assertEqual(before, fp.fingerprint(tree, config), name)
            with (tree / "Dockerfile").open("a") as file:
                file.write("\n# extension-only instruction\n")
            self.assertEqual(before, fp.fingerprint(tree, config))
            with (tree / "scripts/build-kernel.sh").open("a") as file:
                file.write("\n# kernel compile change\n")
            self.assertNotEqual(before, fp.fingerprint(tree, config))

    def test_signing_certificate_id_is_stable_and_rotates(self):
        with tempfile.TemporaryDirectory() as temp:
            ids = []
            for index in range(2):
                key = Path(temp) / f"test-{index}.pem"
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=Offline test only", "-keyout", str(key), "-out", str(key)], check=True, capture_output=True)
                command = ["bash", str(ROOT / "scripts/signing-key-id.sh"), str(key)]
                digest = subprocess.check_output(command, text=True).strip()
                self.assertRegex(digest, r"^[a-f0-9]{64}$")
                self.assertEqual(digest, subprocess.check_output(command, text=True).strip())
                ids.append(digest)
            self.assertNotEqual(*ids)
            invalid = subprocess.run(["bash", str(ROOT / "scripts/signing-key-id.sh"), str(Path(temp) / "absent")], capture_output=True)
            self.assertNotEqual(invalid.returncode, 0)

    def test_required_builder_never_creates_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / "docker"
            log = Path(temp) / "calls"
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_DOCKER_LOG"\nexit 1\n')
            executable.chmod(0o755)
            env = dict(os.environ, PATH=temp + os.pathsep + os.environ["PATH"], TEST_DOCKER_LOG=str(log))
            result = subprocess.run(["make", "builder", "BUILDER=blacksmith-required", "REQUIRE_EXISTING_BUILDER=true"], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("create", log.read_text())
            self.assertIn("Required persisted builder missing", result.stderr)

    def test_narrow_mounts_and_compile_output_reuse(self):
        dockerfile = (ROOT / "Dockerfile").read_text()
        self.assertNotIn("source=scripts,target=", dockerfile)
        self.assertIn("FROM kernel-build AS nvidia-build", dockerfile)
        kernel = dockerfile.split("# BEGIN KERNEL INPUTS")[1].split("# END KERNEL INPUTS")[0]
        self.assertNotIn("NVIDIA_VERSION", kernel)
        self.assertNotIn("extension/", kernel)
        self.assertIn("from=linux-downloads", kernel)
        self.assertIn("ARG MODULE_SIGNING_CERT_SHA256", kernel)
        self.assertIn("MODULE_SIGNING_CERT_SHA256 = MODULE_SIGNING_CERT_SHA256", (ROOT / "docker-bake.hcl").read_text())
        self.assertIn("MODULE_SIGNING_CERT_SHA256:?", (ROOT / "scripts/build-kernel.sh").read_text())

    def test_thinlto_partition_and_secret_mount(self):
        dockerfile = (ROOT / "Dockerfile").read_text()
        self.assertIn("thinlto-${TARGETARCH}-${KERNEL_PAGE_SIZE}-${TOOLCHAIN_CACHE_ID}", dockerfile)
        self.assertIn("target=/var/cache/thinlto,sharing=locked", dockerfile)
        self.assertIn("--thinlto-cache-dir=${THINLTO_CACHE_DIR}", (ROOT / "scripts/build-kernel.sh").read_text())
        for line in dockerfile.splitlines():
            if "module_signing_key" in line:
                self.assertIn("type=secret", line)
        self.assertIn('CONFIG_MODULE_SIG_KEY="/run/secrets/module_signing_key"', (ROOT / "kernel/config").read_text())

    def test_ci_persists_layers_and_cache_mounts(self):
        ci = (ROOT / ".github/workflows/build.yaml").read_text()
        self.assertIn("useblacksmith/setup-docker-builder@19215110ab936351210feebdfa5b440b4493e184", ci)
        self.assertIn("cache-key: talos-dgx-arm64-buildkit-v1", ci)
        self.assertIn("nofallback: true", ci)
        self.assertIn("REQUIRE_EXISTING_BUILDER=true", ci)
        self.assertIn("buildkit-version: v0.33.1", ci)
        self.assertIn("max-parallelism: 1", ci)
        self.assertNotIn("docker/setup-buildx-action", ci)

    def test_shell_syntax(self):
        for script in sorted((ROOT / "scripts").glob("*.sh")):
            subprocess.run(["bash", "-n", str(script)], check=True)
