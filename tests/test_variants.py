import copy
from contextlib import redirect_stdout
import io
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
art = importlib.import_module("artifacts")

spec = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/publish-installers.py")
assert spec is not None and spec.loader is not None
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def make(*args):
    return subprocess.run(["make", "--no-print-directory", *args], cwd=ROOT, capture_output=True, text=True)


def fixture_oci(out, name):
    # Explicit tiny test fixtures, NOT compiled kernel or installer artifacts.
    data = json.dumps({"offline_fixture": name}).encode()
    digest = hashlib.sha256(data).hexdigest()
    layout = out / "oci" / name
    blob = layout / "blobs/sha256" / digest
    blob.parent.mkdir(parents=True, exist_ok=True)
    blob.write_bytes(data)
    (layout / "index.json").write_text(json.dumps({"manifests": [{"digest": "sha256:" + digest}]}))


def fixture_release(out):
    fixture_oci(out, "common/dispram-extension")
    fixture_oci(out, "common/toolkit-extension")
    with patch.dict(os.environ, {"MODULE_SIGNING_CERT_SHA256": "a" * 64}):
        for page in ("4k", "64k"):
            fixture_oci(out, "kernels/" + page)
            fixture_oci(out, "talos/" + page + "/installer-base")
            art.save(out / "shared" / (page + ".json"), art.shared_identity(out, "open-" + page))
        for variant in art.VARIANTS:
            fixture_oci(out, "variants/" + variant + "/nvidia-extension")
            for name in art.artifact_names(variant):
                (out / name).write_text("Offline packaging test fixture: " + name)
            art.record_variant(out, variant)
    art.finalize(out)


def records_source(out):
    return json.loads((out / "VARIANTS.json").read_text())["variants"][0]["source_commit"]


class VariantContract(unittest.TestCase):
    def test_make_matrix_and_shared_kernel_identity(self):
        values = {}
        for variant in art.VARIANTS:
            result = make("print-variant", "VARIANT=" + variant)
            self.assertEqual(result.returncode, 0, result.stderr)
            values[variant] = result.stdout.splitlines()
            self.assertEqual(values[variant][-1], art.TAG)
        self.assertEqual(values["proprietary-4k"][1:], values["open-4k"][1:])
        self.assertNotEqual(values["open-4k"][1], values["open-64k"][1])
        self.assertNotEqual(values["open-4k"][2], values["open-64k"][2])

    def test_invalid_matrix_fails_before_any_build(self):
        for args in (("VARIANT=proprietary-64k",), ("VARIANT=open-16k",),
                     ("VARIANT=open-64k-packing-off",), ("VARIANT=../open-4k",),
                     ("VARIANT=proprietary-4k", "KERNEL_PAGE_SIZE=64k"),
                     ("VARIANT=open-64k", "KERNEL_CONFIG=kernel/config-4k"),
                     ("VARIANT=open-4k", "KERNEL_RELEASE=6.17.13-talos-dgx1022.6-64k"),
                     ("TAG=v1.14.1-dgx1022.5",)):
            with self.subTest(args=args):
                result = make("print-variant", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("docker", result.stdout)
        for variant in (*art.VARIANTS, "proprietary-64k", "open-16k"):
            result = subprocess.run(["bash", str(ROOT / "scripts/validate-variant.sh"), *variant.split("-")], capture_output=True)
            self.assertEqual(result.returncode == 0, variant in art.VARIANTS)

    def test_ordered_build_graph_builds_linux_twice_not_three_times(self):
        result = make("-n", "all", "SIGNING_KEY=/dev/null")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [line for line in result.stdout.splitlines() if line.startswith("docker buildx bake")]
        targets = [line.split()[-1] for line in lines]
        self.assertEqual(targets, ["dispram-extension", "toolkit-extension", "kernel", "talos", "nvidia-extension", "nvidia-extension", "kernel", "talos", "nvidia-extension"])
        self.assertIn(".NOTPARALLEL:", (ROOT / "Makefile").read_text())

    def test_configs_are_exact_historical_inputs_except_release(self):
        baselines = {
            "4k": ("1", "3de7651cd16a4c94fe01fa725c568c55e39138a46297f755a25174e291e3c92c"),
            "64k": ("5", "d76f5547bd84f47cfee765215316f9a42b55c0d9609c16ecf1ec959917d20bd5"),
        }
        for page, (revision, expected) in baselines.items():
            text = (ROOT / ("kernel/config-" + page)).read_text()
            original = text.replace("-talos-dgx1022.6-" + page, "-talos-dgx1022." + revision)
            self.assertEqual(hashlib.sha256(original.encode()).hexdigest(), expected)
            for required in ('CONFIG_MODULE_SIG_KEY="/run/secrets/module_signing_key"', "CONFIG_MODULE_SIG_SHA512=y", "CONFIG_DEBUG_INFO_BTF=y", "CONFIG_LTO_CLANG_THIN=y"):
                self.assertIn(required, text)
        self.assertIn("CONFIG_CMA_SIZE_MBYTES=128", (ROOT / "kernel/config-4k").read_text())
        self.assertIn("CONFIG_CMA_SIZE_MBYTES=1024", (ROOT / "kernel/config-64k").read_text())
        self.assertIn("CONFIG_VMXNET3=m", (ROOT / "kernel/config-4k").read_text())
        self.assertNotIn("CONFIG_VMXNET3=m", (ROOT / "kernel/config-64k").read_text())

    def test_driver_sources_and_required_patch_pair(self):
        script = (ROOT / "scripts/build-nvidia.sh").read_text()
        self.assertIn("open) driver_dir=kernel-open", script)
        self.assertIn("proprietary) driver_dir=kernel", script)
        self.assertIn('${nvidia_src}/${driver_dir}/Module.symvers', script)
        self.assertIn('${nvidia_src}/${driver_dir}/nvidia', script)
        self.assertIn('cmp "${patches}/series"', script)
        self.assertEqual((ROOT / "extension/patches/series").read_text().splitlines(), list(art.PATCHES))
        for name in art.PATCHES:
            self.assertIn(name, script)
        packing = (ROOT / "extension/patches" / art.PATCHES[1]).read_text()
        self.assertIn("PAGE_SIZE != 65536", packing)
        self.assertIn("uvm_pack_sysmem_leaf_tables = true", packing)

    def test_extension_metadata_tracks_each_variant(self):
        for variant in art.VARIANTS:
            text = (ROOT / "extension" / variant / "manifest.yaml").read_text()
            page = art.page_of(variant)
            self.assertIn(art.TAG + "-" + variant, text)
            self.assertIn("6.17.13-talos-dgx1022.6-" + page, text)
            spdx = json.loads((ROOT / "extension" / variant / "nvidia.spdx.json").read_text())
            self.assertIn("-" + page, spdx["documentNamespace"])
            self.assertEqual(spdx["packages"][0]["versionInfo"], "580.178.04")
            self.assertEqual(spdx["packages"][1]["versionInfo"], "2.29.4")
            if variant.startswith("proprietary"):
                self.assertNotIn("open", spdx["name"])
                self.assertEqual(spdx["packages"][0]["licenseDeclared"], "NOASSERTION")

    def test_profiles_select_the_correct_oci_inputs(self):
        for variant in art.VARIANTS:
            for kind in ("installer", "iso"):
                text = subprocess.check_output([sys.executable, str(ROOT / "scripts/render-profile.py"), kind, variant], text=True)
                self.assertIn("/oci/variants/" + variant + "/nvidia-extension", text)
                self.assertIn("/oci/talos/" + art.page_of(variant) + "/installer-base", text)
                self.assertIn("/oci/common/dispram-extension", text)
                self.assertIn("/oci/common/toolkit-extension", text)
                self.assertNotIn("@PAGE@", text)
                self.assertNotIn("imageRef: ghcr.io", text)

    def test_talos_page_specific_constant_and_vmxnet3(self):
        self.assertNotIn("DefaultKernelVersion", (ROOT / "talos/source.patch").read_text())
        for page in ("4k", "64k"):
            with tempfile.TemporaryDirectory() as temp:
                source = Path(temp)
                constant = source / "pkg/machinery/constants/constants.go"
                constant.parent.mkdir(parents=True)
                constant.write_text('DefaultKernelVersion = "6.18.51-talos"\n')
                modules = source / "hack/modules-arm64.txt"
                modules.parent.mkdir()
                modules.write_text("kernel/drivers/net/vmxnet3/vmxnet3.ko\n")
                release = "6.17.13-talos-dgx1022.6-" + page
                subprocess.run([sys.executable, str(ROOT / "scripts/prepare-talos.py"), str(source), release, page], check=True)
                self.assertIn(release, constant.read_text())
                self.assertEqual("vmxnet3" in modules.read_text(), page == "4k")

    @unittest.skipUnless(shutil.which("docker"), "Docker CLI required for bake parser only")
    def test_real_bake_parser_separates_driver_and_kernel_inputs(self):
        kernels = {}
        env = dict(os.environ)
        for variant in art.VARIANTS:
            driver, page = variant.split("-")
            env = dict(os.environ, OUT=str(ROOT / "_out"), TALOS_SRC=str(ROOT / (".work/talos-" + page)), TALOS_VERSION="v1.14.1", TALOS_COMMIT=art.TALOS_COMMIT,
                       KERNEL_RELEASE="6.17.13-talos-dgx1022.6-" + page, KERNEL_CONFIG="kernel/config-" + page,
                       KERNEL_PAGE_SIZE=page, DRIVER_FLAVOR=driver, VARIANT=variant, SOURCE_DATE_EPOCH="1789481248",
                       SIGNING_KEY="/dev/null", MODULE_SIGNING_CERT_SHA256="a" * 64, KBUILD_BUILD_VERSION="offline-" + page)
            result = subprocess.run(["docker", "buildx", "bake", "--print", "kernel", "nvidia-extension", "dispram-extension", "toolkit-extension"], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            targets = json.loads(result.stdout)["target"]
            kernels[variant] = targets["kernel"]
            self.assertNotIn("DRIVER_FLAVOR", targets["kernel"]["args"])
            self.assertNotIn("VARIANT", targets["kernel"]["args"])
            self.assertEqual(targets["nvidia-extension"]["args"]["DRIVER_FLAVOR"], driver)
            self.assertEqual(targets["nvidia-extension"]["args"]["EXTENSION_NAME"], "nvidia-open-gpu-kernel-modules-lts" if driver == "open" else "nvidia-gpu-kernel-modules-lts")
            self.assertTrue(targets["nvidia-extension"]["output"][0]["dest"].endswith("/variants/" + variant + "/nvidia-extension"))
            self.assertNotIn("secret", targets["dispram-extension"])
            self.assertNotIn("secret", targets["toolkit-extension"])
        self.assertEqual(kernels["proprietary-4k"], kernels["open-4k"])
        self.assertNotEqual(kernels["open-4k"], kernels["open-64k"])
        env.update(VARIANT="proprietary-64k", DRIVER_FLAVOR="proprietary", KERNEL_PAGE_SIZE="64k")
        result = subprocess.run(["docker", "buildx", "bake", "--print", "nvidia-extension"], cwd=ROOT, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        env.update(VARIANT="open-64k", DRIVER_FLAVOR="open", KERNEL_CONFIG="kernel/config-4k")
        result = subprocess.run(["docker", "buildx", "bake", "--print", "kernel"], cwd=ROOT, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_every_release_asset_is_uploaded_and_no_duplicate_publish_trigger(self):
        build = (ROOT / ".github/workflows/build.yaml").read_text()
        workflow = (ROOT / ".github/workflows/publish.yaml").read_text()
        for variant in art.VARIANTS:
            for name in art.artifact_names(variant):
                self.assertIn("_out/" + name, build)
        for name in ("SHA256SUMS", "OCI-DIGESTS", "VARIANTS.json"):
            self.assertIn("_out/" + name, build)
            self.assertIn("--pattern " + name, workflow)
        self.assertNotRegex(workflow, r"(?m)^  release:")
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("--installers-only", workflow)
        self.assertIn("notes-readback.json", workflow)


class ArtifactContract(unittest.TestCase):
    def test_full_matrix_checksums_and_provenance_roundtrip(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            records = art.verify(out)
            self.assertEqual(len(records), 3)
            self.assertEqual(len((out / "SHA256SUMS").read_text().splitlines()), 8)
            self.assertEqual(len((out / "OCI-DIGESTS").read_text().splitlines()), 9)
            self.assertNotIn("PRIVATE KEY", (out / "VARIANTS.json").read_text())
            (out / art.artifact_names("open-4k")[0]).write_text("tampered test fixture")
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                art.verify(out)

    def test_missing_variants_or_checksum_entries_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            records = art.verify(out)
            with self.assertRaisesRegex(ValueError, "variant matrix"):
                art.validate_records(records[:-1])
            sums = out / "SHA256SUMS"
            sums.write_text("\n".join(sums.read_text().splitlines()[:-1]) + "\n")
            with self.assertRaisesRegex(ValueError, "exactly six artifacts"):
                art.verify(out)

    def test_kernel_divergence_missing_fixes_and_signer_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            records = art.verify(out)
            for index, field, value in ((0, "kernel_oci_digest", "sha256:" + "0" * 64),
                                        (2, "patches", {}), (2, "module_signing_certificate_sha256", "b" * 64)):
                broken = copy.deepcopy(records)
                broken[index][field] = value
                with self.assertRaises(ValueError):
                    art.validate_records(broken)

    def test_stale_shared_output_rejected_on_signer_rotation(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            with patch.dict(os.environ, {"MODULE_SIGNING_CERT_SHA256": "b" * 64}):
                with self.assertRaisesRegex(ValueError, "Stale shared"):
                    art.check_shared(out, "open-4k")

    def test_publish_verification_needs_all_installers_not_isos(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            for variant in art.VARIANTS:
                (out / art.artifact_names(variant)[1]).unlink()
            self.assertEqual(len(art.verify(out, installers_only=True)), 3)
            with self.assertRaises(OSError):
                art.verify(out)
            (out / art.artifact_names("open-64k")[0]).unlink()
            with self.assertRaises(OSError):
                art.verify(out, installers_only=True)

    def test_publish_conflict_and_auth_fail_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            expected = "sha256:" + "1" * 64
            for code, stderr, stdout in ((0, "", "sha256:" + "2" * 64), (1, "UNAUTHORIZED", "")):
                source = records_source(out)
                with patch.object(publisher, "output", return_value=expected), patch.object(publisher.subprocess, "check_output", return_value=source), patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], code, stdout, stderr)) as run:
                    with self.assertRaises(ValueError):
                        publisher.publish(out, "example.test/installer", art.TAG)
                    self.assertTrue(all(call.args[0][1] == "digest" for call in run.call_args_list))

    def test_publish_source_mismatch_and_last_tag_conflict_stop_all_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            expected = "sha256:" + "1" * 64
            with patch.object(publisher.subprocess, "check_output", return_value="f" * 40), patch.object(publisher.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "source commit"):
                    publisher.publish(out, "example.test/installer", art.TAG)
                run.assert_not_called()
            lookups = [subprocess.CompletedProcess([], 0, expected, ""),
                       subprocess.CompletedProcess([], 0, expected, ""),
                       subprocess.CompletedProcess([], 0, "sha256:" + "2" * 64, "")]
            with patch.object(publisher, "output", return_value=expected), patch.object(publisher.subprocess, "check_output", return_value=records_source(out)), patch.object(publisher.subprocess, "run", side_effect=lookups) as run:
                with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                    publisher.publish(out, "example.test/installer", art.TAG)
                self.assertEqual(run.call_count, 3)
                self.assertTrue(all(call.args[0][1] == "digest" for call in run.call_args_list))

    def test_publish_existing_identical_tags_are_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            expected = "sha256:" + "1" * 64
            with patch.object(publisher, "output", return_value=expected), patch.object(publisher.subprocess, "check_output", return_value=records_source(out)), patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, expected, "")) as run, redirect_stdout(io.StringIO()):
                publisher.publish(out, "example.test/installer", art.TAG)
                self.assertEqual(run.call_count, 3)
                self.assertTrue(all(call.args[0][1] == "digest" for call in run.call_args_list))

    def test_publish_new_tags_verifies_each_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            fixture_release(out)
            expected = "sha256:" + "1" * 64
            def command(args, **kwargs):
                if args[1] == "digest":
                    return subprocess.CompletedProcess(args, 1, "", "MANIFEST_UNKNOWN")
                return subprocess.CompletedProcess(args, 0)
            with patch.object(publisher, "output", return_value=expected) as output, patch.object(publisher.subprocess, "check_output", return_value=records_source(out)), patch.object(publisher.subprocess, "run", side_effect=command) as run:
                with redirect_stdout(io.StringIO()):
                    publisher.publish(out, "example.test/installer", art.TAG)
                pushed = [call.args[0][-1] for call in run.call_args_list if call.args[0][1] == "push"]
                self.assertEqual(pushed, ["example.test/installer:" + art.TAG + "-" + v for v in art.VARIANTS])
                self.assertEqual(len(output.call_args_list), 6)  # local digest + remote read-back per variant
                self.assertEqual(len((out / "INSTALLER-REFS").read_text().splitlines()), 3)
            with self.assertRaisesRegex(ValueError, "only publishes"):
                publisher.publish(out, "example.test/installer", "v1.14.1-dgx1022.5")
