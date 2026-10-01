"""Small, offline tests. Git fixtures and module bytes are synthetic, not release evidence."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package", ROOT / "package.py")
assert spec is not None and spec.loader is not None
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class Workspace(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="talos-package-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "talos").mkdir()
        for name in ("build.json", "installer.yaml", "source.patch"):
            shutil.copyfile(ROOT / "talos" / name, self.root / "talos" / name)
        self.lock = package.load_lock(self.root)

    def write_lock(self, lock):
        (self.root / "talos/build.json").write_text(json.dumps(lock))


class LockTests(Workspace):
    def test_all_58_images_are_pinned(self):
        args = self.lock["build_args"]
        self.assertEqual(sum("@sha256:" in v for v in args.values()), 58)
        self.assertTrue(package.IMAGE_REF.fullmatch(package.VALIDATOR))

    def test_malformed_commit_is_not_repaired(self):
        for value in ("v1.14.1", self.lock["commit"] + "\n", self.lock["commit"][:-1]):
            with self.subTest(value=value):
                lock = copy.deepcopy(self.lock)
                lock["commit"] = value
                self.write_lock(lock)
                with self.assertRaisesRegex(ValueError, "full lowercase SHA"):
                    package.load_lock(self.root)

    def test_unpinned_and_missing_images_fail_closed(self):
        for key in ("PKG_FHS", "TOOLS"):
            with self.subTest(key=key):
                lock = copy.deepcopy(self.lock)
                lock["build_args"][key] = lock["build_args"][key].split("@")[0]
                self.write_lock(lock)
                with self.assertRaisesRegex(ValueError, "Unpinned"):
                    package.load_lock(self.root)
        lock = copy.deepcopy(self.lock)
        del lock["build_args"]["PKG_FHS"]
        self.write_lock(lock)
        with self.assertRaisesRegex(ValueError, "57 package"):
            package.load_lock(self.root)

    def test_wrong_context_and_mismatched_sha_fail(self):
        for key, value in (("SHA", "0" * 40), ("PKG_KERNEL", "stockkernel"), ("INSTALLER_ARCH", "amd64")):
            lock = copy.deepcopy(self.lock)
            lock["build_args"][key] = value
            self.write_lock(lock)
            with self.subTest(key=key), self.assertRaises(ValueError):
                package.load_lock(self.root)

    def test_profile_mutation_fails_before_build(self):
        profile = self.root / "talos/installer.yaml"
        profile.write_text(profile.read_text().replace("secureboot: false", "secureboot: true"))
        with self.assertRaisesRegex(ValueError, "Installer profile changed"):
            package.load_lock(self.root)


class SourceTests(Workspace):
    def setUp(self):
        super().setUp()
        self.origin = self.root / "origin"
        package.run(["git", "init", "--quiet", self.origin])
        (self.origin / "file").write_text("one\ntwo\nthree\n")
        (self.origin / "other").write_text("unchanged\n")
        (self.origin / ".gitignore").write_text("ignored\n")
        package.git(self.origin, "add", ".")
        package.git(self.origin, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture")
        self.commit = package.git(self.origin, "rev-parse", "HEAD").decode().strip()
        (self.origin / "file").write_text("one\npatched\nthree\n")
        self.patch = self.root / "source.patch"
        self.patch.write_bytes(package.git(self.origin, "diff"))
        (self.origin / "file").write_text("one\ntwo\nthree\n")
        self.checkout = self.root / "checkout"

    def prepare(self):
        return package.prepare_source(self.checkout, str(self.origin), self.commit, self.patch)

    def test_real_fetch_patch_and_repeat_without_kernel(self):
        self.prepare()
        self.assertEqual(package.git(self.checkout, "rev-parse", "HEAD").decode().strip(), self.commit)
        self.assertEqual((self.checkout / "file").read_text(), "one\npatched\nthree\n")
        before = package.git(self.checkout, "diff")
        self.prepare()
        self.assertEqual(package.git(self.checkout, "diff"), before)

    def test_modified_source_is_rejected_not_reset(self):
        self.prepare()
        for name in ("other", "file"):
            with self.subTest(name=name):
                path = self.checkout / name
                original = path.read_bytes()
                path.write_bytes(original + b"unexpected\n")
                with self.assertRaisesRegex(ValueError, "Unexpected source changes"):
                    self.prepare()
                self.assertEqual(path.read_bytes(), original + b"unexpected\n")
                path.write_bytes(original)

    def test_ignored_untracked_and_staged_changes_fail(self):
        self.prepare()
        for name in ("ignored", "extra"):
            path = self.checkout / name
            path.write_text("unexpected")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Untracked/ignored"):
                self.prepare()
            path.unlink()
        package.git(self.checkout, "add", "file")
        with self.assertRaisesRegex(ValueError, "Staged source changes"):
            self.prepare()

    def test_wrong_head_origin_and_patch_fail(self):
        self.prepare()
        with self.assertRaisesRegex(ValueError, "HEAD mismatch"):
            package.prepare_source(self.checkout, str(self.origin), "0" * 40, self.patch)
        package.git(self.checkout, "remote", "set-url", "origin", str(self.root / "other-origin"))
        with self.assertRaisesRegex(ValueError, "origin mismatch"):
            self.prepare()
        package.git(self.checkout, "remote", "set-url", "origin", str(self.origin))
        self.patch.write_text(self.patch.read_text().replace("-two", "-missing"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()

    def test_prepare_sources_mode_really_prepares_source(self):
        lock = copy.deepcopy(self.lock)
        lock.update(repository=str(self.origin), commit=self.commit)
        shutil.copyfile(self.patch, self.root / "talos/source.patch")
        with mock.patch.object(package, "ROOT", self.root), mock.patch.object(package, "load_lock", return_value=lock), \
                mock.patch.object(package, "prepare_recipe") as recipe, contextlib.redirect_stdout(io.StringIO()):
            package.main(["--prepare-sources"])
        self.assertEqual((self.root / ".work/talos/file").read_text(), "one\npatched\nthree\n")
        recipe.assert_called_once()


class RecipeTests(Workspace):
    def test_download_and_cache_hashes(self):
        data = b"recipe fixture\n"
        hashes = {"files/nvidia.conf": hashlib.sha256(data).hexdigest()}
        with mock.patch.object(package, "RECIPE_HASHES", hashes), \
                mock.patch.object(package.urllib.request, "urlopen", return_value=io.BytesIO(data)) as fetch:
            recipe = package.prepare_recipe(self.root / "recipe")
            self.assertIn(package.EXTENSIONS_COMMIT, fetch.call_args.args[0])
            package.prepare_recipe(recipe)
            fetch.assert_called_once()
            (recipe / "files/nvidia.conf").write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "Cached recipe checksum"):
                package.prepare_recipe(recipe)

    def test_bad_download_is_not_cached(self):
        with mock.patch.object(package.urllib.request, "urlopen", return_value=io.BytesIO(b"bad")):
            with self.assertRaisesRegex(ValueError, "Downloaded recipe checksum"):
                package.prepare_recipe(self.root / "recipe")
        self.assertFalse((self.root / "recipe/manifest.yaml.tmpl").exists())


def module_bytes(release):
    # Deliberately not a cryptographically valid signature: structural fixture only.
    elf = bytearray(64)
    elf[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", elf, 18, 183)
    elf += b"\0vermagic=" + release.encode() + b" SMP modversions aarch64\0"
    signature = b"synthetic-cms"
    return bytes(elf) + signature + struct.pack(">BBBBB3sI", 0, 0, 2, 0, 0, b"\0\0\0", len(signature)) + package.SIGNATURE_MAGIC


class StageTests(Workspace):
    def setUp(self):
        super().setUp()
        self.release = self.lock["kernel_release"]
        self.prefix = Path("usr/lib/modules") / self.release
        self.native = self.root / ".work/kernel-root"
        self.external = self.root / ".work/nvidia-root"
        self.stage = self.root / "stage"
        self.source = self.root / "source"
        (self.source / "hack").mkdir(parents=True)
        self.selection = ["kernel/fixture/driver%d.ko" % n for n in range(320)]
        self.selection.append("kernel/drivers/net/ethernet/realtek/r8127/r8127.ko")
        (self.source / "hack/modules-arm64.txt").write_text("\n".join(self.selection + sorted(package.METADATA)) + "\n")
        self.data = module_bytes(self.release)
        for tree, names in ((self.native, self.selection), (self.external, package.NVIDIA_MODULES)):
            for name in names:
                path = tree / self.prefix / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(self.data)
            for name in package.METADATA:
                (tree / self.prefix / name).write_text("native\n" if tree == self.native else "stale-external.o\n")
        (self.native / "boot").mkdir()
        (self.native / "boot/vmlinuz").write_bytes(b"kernel fixture")
        (self.native / "boot/System.map").write_bytes(b"symbol fixture")
        self.recipe = self.root / "recipe"
        (self.recipe / "files").mkdir(parents=True)
        (self.recipe / "files/nvidia.conf").write_text("blacklist nvidia\n")
        (self.recipe / "manifest.yaml.tmpl").write_text("version: {{ .VERSION }}\ntier: {{ .TIER }}\n")

    def stage_inputs(self):
        return package.stage_inputs(self.root, self.source, self.recipe, self.stage, self.lock)

    def test_exact_payload_native_metadata_spdx_and_deterministic_tar(self):
        extension = self.stage_inputs()
        rootfs = extension / "rootfs"
        self.assertEqual(len(list((self.stage / "kernel-root").rglob("*.ko"))), 321)
        self.assertEqual({p.relative_to(rootfs / self.prefix).as_posix() for p in rootfs.rglob("*.ko")}, package.NVIDIA_MODULES)
        for name in package.METADATA:
            self.assertEqual((rootfs / self.prefix / name).read_bytes(), b"native\n")
        sbom_path = rootfs / "usr/local/share/spdx/kmod-nvidia-lts.spdx.json"
        sbom = json.loads(sbom_path.read_text())
        self.assertEqual(len(sbom["files"]), 10)  # six modules, three metadata files, modprobe policy
        self.assertIn("580.178.04-v1.14.1-dgx1022-buildonly", (extension / "manifest.yaml").read_text())
        hashes = []
        for item in sbom["files"]:
            path = rootfs / item["fileName"]
            self.assertEqual(item["checksums"][1]["checksumValue"], package.digest(path))
            self.assertEqual(item["checksums"][0]["checksumValue"], package.digest(path, "sha1"))
            hashes.append(item["checksums"][0]["checksumValue"])
        self.assertEqual(sbom["packages"][0]["packageVerificationCode"]["packageVerificationCodeValue"],
                         hashlib.sha1("".join(sorted(hashes)).encode()).hexdigest())
        epoch = int(self.lock["build_args"]["SOURCE_DATE_EPOCH"])
        before = sbom_path.read_bytes()
        package.write_spdx(rootfs, sbom_path, "kmod-nvidia-lts", "580.178.04", epoch, "NOASSERTION")
        self.assertEqual(before, sbom_path.read_bytes())
        a, b = self.root / "a.tar", self.root / "b.tar"
        package.extension_tar(extension, a, epoch)
        package.extension_tar(extension, b, epoch)
        self.assertEqual(package.digest(a), package.digest(b))
        with tarfile.open(a) as archive:
            self.assertTrue(all(m.uid == m.gid == 0 and m.mtime == epoch for m in archive))
            self.assertIn("manifest.yaml", archive.getnames())

    def test_missing_module_metadata_and_wrong_release_fail(self):
        missing = self.native / self.prefix / self.selection[0]
        missing.unlink()
        with self.assertRaises(OSError):
            self.stage_inputs()
        missing.write_bytes(self.data)
        (self.native / self.prefix / "modules.builtin").unlink()
        with self.assertRaisesRegex(ValueError, "Missing regular input"):
            self.stage_inputs()
        (self.external / "usr/lib/modules/wrong-release").mkdir()
        with self.assertRaisesRegex(ValueError, "Wrong module release"):
            self.stage_inputs()

    def test_extra_external_module_and_symlink_fail(self):
        extra = self.external / self.prefix / "extras/unexpected.ko"
        extra.write_bytes(self.data)
        with self.assertRaisesRegex(ValueError, "exactly six"):
            self.stage_inputs()
        extra.unlink()
        extra.symlink_to(self.native / "boot/vmlinuz")
        with self.assertRaisesRegex(ValueError, "Symlinks/special"):
            self.stage_inputs()

    def test_wrong_architecture_release_and_unsigned_module_fail(self):
        path = self.native / self.prefix / self.selection[0]
        bad_arch = bytearray(self.data)
        struct.pack_into("<H", bad_arch, 18, 62)
        for data, error in ((bad_arch, "ARM64 ELF"), (module_bytes("wrong"), "release mismatch"),
                            (self.data[:-len(package.SIGNATURE_MAGIC)], "Unsigned module")):
            path.write_bytes(data)
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                self.stage_inputs()

    def test_private_keys_and_path_escape_are_rejected(self):
        (self.native / "boot/System.map").write_bytes(b"-----BEGIN RSA PRIVATE KEY-----\n")
        with self.assertRaisesRegex(ValueError, "Private signing key"):
            self.stage_inputs()
        selection = self.source / "hack/modules-arm64.txt"
        selection.write_text(selection.read_text().replace(self.selection[0], "kernel/../../escape.ko"))
        with self.assertRaisesRegex(ValueError, "321 native"):
            self.stage_inputs()


class CommandTests(Workspace):
    def test_targets_platforms_installer_arch_and_local_paths(self):
        stage = self.root / ".work/package"
        steps = package.commands(self.root, stage, self.lock)
        self.assertEqual(len(steps), 6)
        self.assertIn(package.VALIDATOR, steps[0])
        self.assertIn("--network=none", steps[0])
        for command, target in zip(steps[1:5], ("kernel", "initramfs", "installer-base", "imager")):
            self.assertIn("--target=" + target, command)
            self.assertIn("--platform=linux/" + ("amd64" if target == "imager" else "arm64"), command)
            self.assertIn("--build-arg=INSTALLER_ARCH=" + ("arm64" if target == "imager" else "targetarch"), command)
            self.assertEqual(sum(x.startswith("--build-arg=INSTALLER_ARCH=") for x in command), 1)
            self.assertIn("--build-context=kernelcustom=" + str(stage / "kernel-root"), command)
            self.assertIn("--push=false", command)
            self.assertEqual(command[-1], str(self.root / ".work/talos"))
            self.assertIn("--build-arg=GO_BUILDFLAGS=" + self.lock["build_args"]["GO_BUILDFLAGS"], command)
        self.assertIn("--output=type=oci,tar=false,dest=" + str(stage / "assets/installer-base"), steps[3])
        self.assertIn("--output=type=docker", steps[4])
        self.assertEqual(steps[-1][-3:], [package.IMAGER, "-", "--output=/out"])
        self.assertIn("-i", steps[-1])
        self.assertIn("type=bind,src=" + str(stage / "assets") + ",dst=/assets,readonly", steps[-1])
        self.assertFalse(any("--privileged" in x for command in steps for x in command))

    def test_plan_has_no_source_kernel_or_docker_prerequisite(self):
        stream = io.StringIO()
        with mock.patch.object(package, "ROOT", self.root), mock.patch.object(package, "run") as run, \
                mock.patch.object(package, "prepare_source") as prepare, contextlib.redirect_stdout(stream):
            package.main(["--plan"])
        run.assert_not_called()
        prepare.assert_not_called()
        plan = json.loads(stream.getvalue())
        self.assertEqual(plan["imager_stdin"], str(self.root / "talos/installer.yaml"))
        self.assertFalse((self.root / ".work").exists())

    def test_cli_help_runs(self):
        result = subprocess.run([sys.executable, str(ROOT / "package.py"), "--help"], check=True, capture_output=True, text=True)
        self.assertIn("--prepare-sources", result.stdout)
        self.assertIn("--plan", result.stdout)


class InstallerTests(Workspace):
    def installer(self, architecture, kernel=b"kernel fixture", profile=b"ID=main"):
        path = self.root / "installer.tar"
        sections = {b".linux": kernel, b".uname": self.lock["kernel_release"].encode(), b".profile": profile,
                    b".cmdline": b"talos.platform=metal console=ttyAMA0 console=tty0 slab_nomerge pti=on "
                    b"consoleblank=0 printk.devkmsg=on selinux=1 module.sig_enforce=1 proc_mem.force_override=never "
                    b"arm64.nobti pci=pcie_bus_safe", b".initrd": b"\x28\xb5\x2f\xfd"}
        uki = bytearray(88 + 40 * len(sections))
        uki[:2] = b"MZ"
        struct.pack_into("<I", uki, 60, 64)
        uki[64:68] = b"PE\0\0"
        struct.pack_into("<HH", uki, 68, 0xaa64, len(sections))
        for index, (name, data) in enumerate(sections.items()):
            offset = 88 + index * 40
            uki[offset:offset + len(name)] = name
            struct.pack_into("<IIII", uki, offset + 8, len(data), 0, len(data), len(uki))
            uki.extend(data)
        layer = io.BytesIO()
        with tarfile.open(fileobj=layer, mode="w") as archive:
            info = tarfile.TarInfo("usr/install/arm64/vmlinuz.efi")
            info.size = len(uki)
            archive.addfile(info, io.BytesIO(uki))
        records = {"manifest.json": json.dumps([{"Config": "config.json", "Layers": ["layer.tar"]}]).encode(),
                   "config.json": json.dumps({"architecture": architecture, "os": "linux"}).encode(),
                   "layer.tar": layer.getvalue()}
        with tarfile.open(path, "w") as archive:
            for name, data in records.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def test_archive_architecture_is_checked(self):
        release, kernel_hash = self.lock["kernel_release"], hashlib.sha256(b"kernel fixture").hexdigest()
        package.verify_installer(self.installer("arm64"), release, kernel_hash)
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            package.verify_installer(self.installer("amd64"), release, kernel_hash)
        with self.assertRaisesRegex(ValueError, "kernel hash mismatch"):
            package.verify_installer(self.installer("arm64", kernel=b"wrong"), release, kernel_hash)
        with self.assertRaisesRegex(ValueError, "Unexpected UKI boot profile"):
            package.verify_installer(self.installer("arm64", profile=b"ID=wipe"), release, kernel_hash)


if __name__ == "__main__":
    unittest.main()
