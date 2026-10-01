#!/usr/bin/env python3
"""Package staged, compiler-verified ARM64 inputs; Python stdlib, git and Docker.

Run on a local AMD64 Docker engine with buildx. The compiler must first populate
.work/kernel-root and .work/nvidia-root and verify their signatures and ABI.
--prepare-sources fetches/verifies sources without Docker or compiled inputs.
--plan prints the actual command construction without downloading or building.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent
EXTENSIONS_COMMIT = "515779a55c15b43088e89b17432181891115cbdf"
RECIPE_URL = ("https://raw.githubusercontent.com/siderolabs/extensions/" +
              EXTENSIONS_COMMIT + "/nvidia-gpu/nonfree/kmod-nvidia/lts/")
RECIPE_HASHES = {
    "manifest.yaml.tmpl": "7c2e05240e1ca2172d3de18f388f0ffb594d812ec6864faa99b4a72bc92be28c",
    "files/nvidia.conf": "a9e8d66e5d2a4b3cba137ee7d9d42eb522ba688bef99ca759ea5843b912c3148",
}
VALIDATOR = ("ghcr.io/siderolabs/extensions-validator@sha256:"
             "3737c0e2f22e66382bddcdaab61e305eae453913ad3ba9b6096e96647daae800")
IMAGER = "talos-dgx-kernel/imager:local"
# Lock the reviewed stdin profile without introducing a YAML dependency/parser.
PROFILE_SHA256 = "623b7a3dd142cce027b2ab17f59b046f080a3a3fd987852dbc8a03bfccb99ab3"
METADATA = {"modules.builtin", "modules.builtin.modinfo", "modules.order"}
NVIDIA_MODULES = {"extras/" + name + ".ko" for name in (
    "nvidia", "nvidia-drm", "nvidia-fs", "nvidia-modeset", "nvidia-peermem", "nvidia-uvm")}
SIGNATURE_MAGIC = b"~Module signature appended~\n"
IMAGE_REF = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[0-9a-f]{64}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(argv, **kwargs):
    return subprocess.run([str(x) for x in argv], check=True, **kwargs)


def git(path, *args, **kwargs):
    return run(["git", "-C", path, *args], capture_output=True, **kwargs).stdout


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def load_lock(root):
    lock = json.loads((root / "talos/build.json").read_text())
    args = lock["build_args"]
    require(re.fullmatch(r"[0-9a-f]{40}", lock["commit"]), "Talos commit must be a full lowercase SHA")
    require(lock["repository"] == "https://github.com/siderolabs/talos.git", "Unexpected Talos repository")
    require(all(isinstance(v, str) for v in args.values()), "Build arguments must be strings")
    require(args["SHA"] == lock["commit"], "Build SHA differs from source commit")
    require(args["TAG"] == args["ABBREV_TAG"] == "v1.14.1", "Profile requires Talos v1.14.1")
    require(args["SOURCE_DATE_EPOCH"].isdigit(), "Invalid SOURCE_DATE_EPOCH")
    require(re.fullmatch(r"[0-9.]+-talos-[a-zA-Z0-9.-]+", lock["kernel_release"]), "Invalid kernel release")
    require(args["PKG_KERNEL"] == "kernelcustom", "Kernel must use the local named context")
    require(args["INSTALLER_ARCH"] == "targetarch", "Unexpected default INSTALLER_ARCH")
    images = []
    for key, value in args.items():
        if not key.startswith("PKG_") or key == "PKG_KERNEL":
            continue
        if key in {"PKG_RASPBERYPI_FIRMWARE", "PKG_U_BOOT"}:
            require(value == "", "Unused firmware argument changed")
        else:
            require(IMAGE_REF.fullmatch(value), "Unpinned package image: " + key)
            images.append(value)
    tools = args["TOOLS_PREFIX"] + ":" + args["TOOLS"]
    require(IMAGE_REF.fullmatch(tools), "Unpinned tools image")
    require(len(images) == 57, "Expected 57 package images plus the tools image")
    require(digest(root / "talos/installer.yaml") == PROFILE_SHA256,
            "Installer profile changed; review it before updating PROFILE_SHA256")
    return lock


def prepare_source(path, repository, commit, patch):
    """Accept only pristine or exactly patched sources; never reset user changes."""
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected an exact source commit")
    require(not path.is_symlink(), "Source checkout must not be a symlink")
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        # An interrupted fetch never leaves a partially accepted checkout.
        with tempfile.TemporaryDirectory(prefix="talos-fetch-", dir=path.parent) as tmp:
            checkout = Path(tmp) / "source"
            run(["git", "init", "--quiet", checkout])
            git(checkout, "remote", "add", "origin", repository)
            git(checkout, "fetch", "--quiet", "--depth=1", "origin", commit)
            require(git(checkout, "rev-parse", "FETCH_HEAD").decode().strip() == commit,
                    "Fetched source commit mismatch")
            git(checkout, "checkout", "--quiet", "--detach", commit)
            checkout.rename(path)
    require((path / ".git").is_dir(), "Expected a dedicated Git checkout")
    require(Path(git(path, "rev-parse", "--show-toplevel").decode().strip()).resolve() == path.resolve(),
            "Source checkout root mismatch")
    require(git(path, "remote", "get-url", "origin").decode().strip() == repository, "Source origin mismatch")
    require(git(path, "rev-parse", "HEAD").decode().strip() == commit, "Source HEAD mismatch")
    require(not git(path, "diff", "--cached", "--name-only", "HEAD"), "Staged source changes are not allowed")
    # No exclude rules: ignored files could also affect the Docker build context.
    require(not git(path, "ls-files", "--others"), "Untracked/ignored source files are not allowed")
    with tempfile.TemporaryDirectory(prefix="talos-index-", dir=path.parent) as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / "index"))
        git(path, "read-tree", commit, env=env)
        pristine = not git(path, "diff", "--no-ext-diff", "--no-textconv", "--name-only", env=env)
        git(path, "apply", "--cached", "--check", patch.resolve(), env=env)
        git(path, "apply", "--cached", patch.resolve(), env=env)
        differs = git(path, "diff", "--no-ext-diff", "--no-textconv", "--name-only", env=env)
        if differs:
            require(pristine, "Unexpected source changes; only talos/source.patch is permitted")
            git(path, "apply", "--check", patch.resolve())
            git(path, "apply", patch.resolve())
        require(not git(path, "diff", "--no-ext-diff", "--no-textconv", "--name-only", env=env),
                "Patched source verification failed")
    return path


def prepare_recipe(path):
    for name, expected in RECIPE_HASHES.items():
        target = path / name
        require(not target.is_symlink(), "Recipe cache must not contain symlinks")
        if not target.exists():
            with urllib.request.urlopen(RECIPE_URL + name, timeout=60) as response:
                data = response.read()
            require(hashlib.sha256(data).hexdigest() == expected, "Downloaded recipe checksum mismatch: " + name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        require(digest(target) == expected, "Cached recipe checksum mismatch: " + name)
    return path


def regular_tree(root):
    require(root.is_dir() and not root.is_symlink(), "Missing or symlinked input directory: " + str(root))
    for path in root.rglob("*"):
        require(not path.is_symlink() and (path.is_file() or path.is_dir()),
                "Symlinks/special files are not allowed: " + str(path))


def check_module(path, release):
    """Structural checks only; the compiler is responsible for CMS/ABI validation."""
    data = path.read_bytes()
    require(len(data) > 64 and data[:6] == b"\x7fELF\x02\x01" and
            struct.unpack_from("<H", data, 18)[0] == 183, "Not an ARM64 ELF module: " + str(path))
    versions = re.findall(rb"\x00vermagic=([^\x00]+)\x00", data)
    require(len(versions) == 1 and versions[0].split()[0] == release.encode(), "Module release mismatch: " + str(path))
    require(data.endswith(SIGNATURE_MAGIC), "Unsigned module: " + str(path))
    end = len(data) - len(SIGNATURE_MAGIC) - 12
    algo, hash_id, kind, signer, key, padding, size = struct.unpack(">BBBBB3sI", data[end:end + 12])
    require(kind == 2 and signer == key == 0 and padding == b"\0\0\0" and 0 < size < end - 64,
            "Invalid module signature trailer: " + str(path))


def copy_public(source, target):
    require(source.is_file() and not source.is_symlink(), "Missing regular input: " + str(source))
    with source.open("rb") as stream:
        previous = b""
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            require(not re.search(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----", previous + chunk),
                    "Private signing key in public input: " + str(source))
            previous = chunk[-128:]
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o644)


def write_spdx(tree, output, name, version, epoch, license_id):
    files = []
    for path in sorted(tree.rglob("*")):
        require(not path.is_symlink(), "Symlink in SPDX input")
        if not path.is_file() or path == output:
            continue
        files.append({"fileName": "./" + path.relative_to(tree).as_posix(),
                      "SPDXID": "SPDXRef-File-" + str(len(files)),
                      "checksums": [{"algorithm": algorithm.upper(), "checksumValue": digest(path, algorithm)}
                                    for algorithm in ("sha1", "sha256")],
                      "licenseConcluded": "NOASSERTION", "licenseInfoInFiles": ["NOASSERTION"],
                      "copyrightText": "NOASSERTION"})
    code = hashlib.sha1("".join(sorted(f["checksums"][0]["checksumValue"] for f in files)).encode()).hexdigest()
    package_id = "SPDXRef-Package-" + name
    document = {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT", "name": name,
        "documentNamespace": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, name + version + code)),
        "creationInfo": {"creators": ["Tool: talos-dgx-kernel/package.py"],
                         "created": datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
        "packages": [{"name": name, "SPDXID": package_id, "versionInfo": version,
                      "downloadLocation": "NOASSERTION", "filesAnalyzed": True,
                      "packageVerificationCode": {"packageVerificationCodeValue": code},
                      "licenseConcluded": "NOASSERTION", "licenseDeclared": license_id,
                      "copyrightText": "NOASSERTION"}],
        "files": files,
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": package_id}] +
                         [{"spdxElementId": package_id, "relationshipType": "CONTAINS",
                           "relatedSpdxElement": f["SPDXID"]} for f in files],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n")


def stage_inputs(root, source, recipe, stage, lock):
    release = lock["kernel_release"]
    epoch = int(lock["build_args"]["SOURCE_DATE_EPOCH"])
    native, external = (root / ".work" / name for name in ("kernel-root", "nvidia-root"))
    for tree in (native, external):
        regular_tree(tree)
        versions = tree / "usr/lib/modules"
        require(versions.is_dir() and {p.name for p in versions.iterdir()} == {release}, "Wrong module release directory")
    prefix = Path("usr/lib/modules") / release
    entries = (source / "hack/modules-arm64.txt").read_text().splitlines()
    selected = {x for x in entries if re.fullmatch(r"kernel/[a-zA-Z0-9_./-]+\.ko", x) and ".." not in Path(x).parts}
    require(len(entries) == len(set(entries)) and set(entries) == selected | METADATA and len(selected) == 321,
            "Expected exactly 321 native modules and three metadata files")
    require("kernel/drivers/net/ethernet/realtek/r8127/r8127.ko" in selected, "RTL8127 module missing from selection")
    ext_files = {p.relative_to(external / prefix).as_posix() for p in (external / prefix).rglob("*") if p.is_file()}
    require({x for x in ext_files if ".ko" in x} == NVIDIA_MODULES, "Expected exactly six NVIDIA/GDS modules")
    kernel, extension = stage / "kernel-root", stage / "extension"
    for entry in sorted(entries):
        path = native / prefix / entry
        if entry in selected:
            check_module(path, release)
        copy_public(path, kernel / prefix / entry)
    for name in ("vmlinuz", "System.map"):
        require((native / "boot" / name).stat().st_size > 0, "Empty kernel boot input")
        copy_public(native / "boot" / name, kernel / "boot" / name)
    for entry in sorted(NVIDIA_MODULES):
        check_module(external / prefix / entry, release)
        copy_public(external / prefix / entry, extension / "rootfs" / prefix / entry)
    # Authoritative installed native metadata, never the external Kbuild .o order.
    for entry in sorted(METADATA):
        copy_public(native / prefix / entry, extension / "rootfs" / prefix / entry)
    copy_public(recipe / "files/nvidia.conf", extension / "rootfs/usr/local/lib/modprobe.d/nvidia.conf")
    version = "580.178.04-" + lock["build_args"]["TAG"] + "-" + release.split("-talos-", 1)[1]
    manifest = (recipe / "manifest.yaml.tmpl").read_text().replace("{{ .VERSION }}", version).replace("{{ .TIER }}", "core")
    require("{{" not in manifest, "Unexpanded extension manifest template")
    (extension / "manifest.yaml").write_text(manifest)
    write_spdx(kernel, kernel / "usr/share/spdx/kernel.spdx.json", "kernel", release, epoch, "GPL-2.0-only")
    write_spdx(extension / "rootfs", extension / "rootfs/usr/local/share/spdx/kmod-nvidia-lts.spdx.json",
               "kmod-nvidia-lts", "580.178.04", epoch, "NOASSERTION")
    for tree in (kernel, extension):
        for path in [tree, *tree.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
    return extension


def extension_tar(extension, output, epoch):
    with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(extension.rglob("*")):
            info = archive.gettarinfo(str(path), arcname=path.relative_to(extension).as_posix())
            require(info.isfile() or info.isdir(), "Nonregular extension archive entry")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = epoch
            info.mode = 0o755 if info.isdir() else 0o644
            if info.isfile():
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
            else:
                archive.addfile(info)


def commands(root, stage, lock):
    """Build and runtime paths always derive from this local checkout."""
    assets = stage / "assets"
    mount = lambda path, target, ro=False: "type=bind,src=" + str(path.resolve()) + ",dst=" + target + (",readonly" if ro else "")
    require("," not in str(root) and "," not in str(stage), "Docker bind paths cannot contain commas")
    result = [["docker", "run", "--rm", "--platform=linux/amd64", "--network=none",
               "--mount", mount(stage / "extension", "/extension", True), VALIDATOR,
               "validate", "--rootfs=/extension", "--pkg-name=nonfree-kmod-nvidia-lts"]]
    for target in ("kernel", "initramfs", "installer-base", "imager"):
        args = dict(lock["build_args"])
        if target == "imager":
            args["INSTALLER_ARCH"] = "arm64"
        command = ["docker", "buildx", "build", "--target=" + target,
                   "--file=" + str(root / ".work/talos/Dockerfile"), "--progress=plain",
                   "--platform=linux/" + ("amd64" if target == "imager" else "arm64"),
                   "--push=false", "--provenance=false", "--sbom=false",
                   "--build-context=kernelcustom=" + str(stage / "kernel-root")]
        command += ["--build-arg=" + key + "=" + value for key, value in args.items()]
        if target == "imager":
            command += ["--output=type=docker", "--tag=" + IMAGER]
        elif target == "installer-base":
            command += ["--output=type=oci,tar=false,dest=" + str(assets / "installer-base")]
        else:
            command += ["--output=type=local,dest=" + str(assets)]
        result.append(command + [str(root / ".work/talos")])
    result.append(["docker", "run", "--rm", "--platform=linux/amd64", "--pull=never", "-i",
                   "--env=SOURCE_DATE_EPOCH=" + lock["build_args"]["SOURCE_DATE_EPOCH"],
                   "--mount", mount(assets, "/assets", True), "--mount", mount(stage / "out", "/out"),
                   IMAGER, "-", "--output=/out"])
    return result


def pe_sections(data):
    require(len(data) >= 64 and data[:2] == b"MZ", "Missing UKI PE header")
    pe = struct.unpack_from("<I", data, 60)[0]
    require(pe + 24 <= len(data) and data[pe:pe + 4] == b"PE\0\0", "Invalid UKI PE header")
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    require(machine == 0xaa64, "UKI is not ARM64")
    start = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
    require(start + count * 40 <= len(data), "Truncated UKI sections")
    sections = {}
    for index in range(count):
        offset = start + index * 40
        name = data[offset:offset + 8].split(b"\0", 1)[0]
        size, address, raw_size, raw_offset = struct.unpack_from("<IIII", data, offset + 8)
        require(raw_offset + raw_size <= len(data) and name not in sections, "Invalid/duplicate UKI section")
        sections[name] = data[raw_offset:raw_offset + min(size, raw_size)]
    return sections


def verify_installer(path, release, kernel_hash):
    # No extraction or execution. This checks image/UKI identity, not the
    # compressed module payload's CMS signatures, ABI, or hardware behavior.
    require(path.is_file() and path.stat().st_size > 0, "Installer output is missing")
    with tarfile.open(path) as archive:
        manifest_file = archive.extractfile("manifest.json")
        if manifest_file is None:
            raise ValueError("Missing installer manifest")
        manifests = json.load(manifest_file)
        require(len(manifests) == 1, "Expected one installer image")
        config_file = archive.extractfile(manifests[0]["Config"])
        if config_file is None:
            raise ValueError("Missing installer configuration")
        config = json.load(config_file)
        require(config["architecture"] == "arm64" and config["os"] == "linux", "Installer architecture mismatch")
        require(manifests[0]["Layers"], "Installer contains no layers")
        sections = None
        for layer in manifests[0]["Layers"]:
            require(archive.getmember(layer).isfile(), "Missing installer layer")
            layer_file = archive.extractfile(layer)
            if layer_file is None:
                raise ValueError("Missing installer layer data")
            with tarfile.open(fileobj=layer_file, mode="r|*") as payload:
                for member in payload:
                    name = member.name.removeprefix("./")
                    if name.startswith("usr/install/"):
                        require(".." not in Path(name).parts and ".wh." not in name, "Unsafe boot asset layer")
                    if name == "usr/install/arm64/vmlinuz.efi":
                        require(sections is None and member.isfile(), "Duplicate/nonregular UKI")
                        stream = payload.extractfile(member)
                        if stream is None:
                            raise ValueError("Missing UKI data")
                        sections = pe_sections(stream.read())
        if sections is None:
            raise ValueError("Installer contains no ARM64 UKI")
        require(hashlib.sha256(sections[b".linux"]).hexdigest() == kernel_hash, "Embedded kernel hash mismatch")
        require(sections[b".uname"].rstrip(b"\0").decode() == release, "UKI kernel release mismatch")
        require(sections[b".profile"].rstrip(b"\0") == b"ID=main", "Unexpected UKI boot profile")
        command_line = sections[b".cmdline"].rstrip(b"\0").decode()
        require(command_line == "talos.platform=metal console=ttyAMA0 console=tty0 slab_nomerge pti=on "
                "consoleblank=0 printk.devkmsg=on selinux=1 module.sig_enforce=1 proc_mem.force_override=never "
                "arm64.nobti pci=pcie_bus_safe", "Unexpected default kernel command line")
        require(sections[b".initrd"].startswith(b"\x28\xb5\x2f\xfd"), "Missing zstd initramfs")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--prepare-sources", action="store_true", help="fetch and verify pinned sources; no Docker or kernel required")
    modes.add_argument("--plan", action="store_true", help="print build argv and stdin profile; no writes, downloads or Docker")
    options = parser.parse_args(argv)
    lock = load_lock(ROOT)
    work = ROOT / ".work"
    if options.plan:
        print(json.dumps({"commands": commands(ROOT, work / "package", lock),
                          "imager_stdin": str(ROOT / "talos/installer.yaml"),
                          "output": str(ROOT / "out/installer-arm64.tar")}, indent=2))
        return
    work.mkdir(exist_ok=True)
    source = prepare_source(work / "talos", lock["repository"], lock["commit"], ROOT / "talos/source.patch")
    recipe = prepare_recipe(work / "extension-recipe")
    if options.prepare_sources:
        print("Pinned Talos source, exact patch, and NVIDIA extension recipe verified.")
        return
    architecture = run(["docker", "info", "--format", "{{.Architecture}}"], capture_output=True, text=True).stdout.strip()
    require(architecture in {"amd64", "x86_64"}, "Packaging requires an AMD64 Docker engine with local bind mounts")
    with tempfile.TemporaryDirectory(prefix="package-", dir=work) as tmp:
        stage = Path(tmp)
        extension = stage_inputs(ROOT, source, recipe, stage, lock)
        (stage / "assets").mkdir()
        (stage / "out").mkdir()
        steps = commands(ROOT, stage, lock)
        run(steps[0])
        extension_tar(extension, stage / "assets/nonfree-kmod-nvidia-lts.tar", int(lock["build_args"]["SOURCE_DATE_EPOCH"]))
        for command in steps[1:-1]:
            run(command)
        run(steps[-1], input=(ROOT / "talos/installer.yaml").read_bytes())
        installer = stage / "out/installer-arm64.tar"
        kernel_hash = digest(stage / "kernel-root/boot/vmlinuz")
        verify_installer(installer, lock["kernel_release"], kernel_hash)
        output = ROOT / "out/installer-arm64.tar"
        output.parent.mkdir(exist_ok=True)
        # Keep the previous installer intact until the new one passes validation.
        with tempfile.NamedTemporaryFile(prefix=".installer-", dir=output.parent, delete=False) as stream:
            pending = Path(stream.name)
        try:
            shutil.copyfile(installer, pending)
            pending.chmod(0o644)
            pending.replace(output)
        finally:
            pending.unlink(missing_ok=True)
        verify_installer(output, lock["kernel_release"], kernel_hash)
        print(str(output) + " sha256:" + digest(output))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit("package: " + str(error))
