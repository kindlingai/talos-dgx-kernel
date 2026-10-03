#!/usr/bin/env python3
"""Record and verify the exact .6 artifact matrix (stdlib only; no private keys)."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TAG = "v1.14.1-dgx1022.6"
VARIANTS = ("proprietary-4k", "open-4k", "open-64k")
PATCHES = ("0001-nvidia-uvm-flush-gpu-tlb-after-hub-ats-faults.patch",
           "0002-nvidia-uvm-pack-user-leaf-page-tables.patch")
TALOS_COMMIT = "2f86b9d2a29b413deddd7122a8420b8913813615"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def page_of(variant):
    require(variant in VARIANTS, "Unsupported variant: " + variant)
    return variant.split("-")[1]


def artifact_names(variant):
    page_of(variant)
    return (f"installer-arm64-{variant}.tar", f"metal-arm64-{variant}.iso")


def oci_digest(out, path):
    layout = out / "oci" / path
    manifests = json.loads((layout / "index.json").read_text())["manifests"]
    require(len(manifests) == 1, "Expected exactly one manifest: " + path)
    digest = manifests[0]["digest"]
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "Invalid OCI digest")
    blob = layout / "blobs/sha256" / digest.split(":")[1]
    require(sha(blob) == digest.split(":")[1], "OCI manifest checksum mismatch: " + path)
    return digest


def shared_identity(out, variant):
    page = page_of(variant)
    certificate = os.environ.get("MODULE_SIGNING_CERT_SHA256", "")
    require(re.fullmatch(r"[0-9a-f]{64}", certificate), "Missing public signing certificate ID")
    fingerprint = subprocess.check_output([sys.executable, str(ROOT / "scripts/kernel-fingerprint.py"), "kernel/config-" + page], text=True).strip()
    return {
        "page_size": page,
        "kernel_release": "6.17.13-talos-dgx1022.6-" + page,
        "kernel_build_fingerprint": fingerprint,
        "kernel_config_sha256": sha(ROOT / ("kernel/config-" + page)),
        "module_signing_certificate_sha256": certificate,
        "talos_commit": TALOS_COMMIT,
        "talos_source_patch_sha256": sha(ROOT / "talos/source.patch"),
        "talos_prepare_script_sha256": sha(ROOT / "scripts/prepare-talos.py"),
        "kernel_oci_digest": oci_digest(out, "kernels/" + page),
        "installer_base_oci_digest": oci_digest(out, "talos/" + page + "/installer-base"),
    }


def check_shared(out, variant):
    page = page_of(variant)
    saved = json.loads((out / "shared" / (page + ".json")).read_text())
    require(saved == shared_identity(out, variant), "Stale shared kernel/Talos outputs; run make talos for this variant")
    return saved


def record_variant(out, variant):
    shared = check_shared(out, variant)
    driver = variant.split("-")[0]
    patches = PATCHES if driver == "open" else ()
    record = dict(shared, variant=variant, driver=driver, tag=TAG,
                  talos_version="v1.14.1", nvidia_version="580.178.04", gds_version="2.29.4",
                  driver_source_directory="kernel-open" if driver == "open" else "kernel",
                  source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  source_date_epoch=1789481248,
                  patches={name: sha(ROOT / "extension/patches" / name) for name in patches},
                  nvidia_oci_digest=oci_digest(out, "variants/" + variant + "/nvidia-extension"),
                  dispram_oci_digest=oci_digest(out, "common/dispram-extension"),
                  artifacts={name: sha(out / name) for name in artifact_names(variant)})
    save(out / "variants" / variant / "provenance.json", record)


def validate_records(records):
    require([r["variant"] for r in records] == list(VARIANTS), "Incomplete or unordered variant matrix")
    for record in records:
        variant = record["variant"]
        driver, page = variant.split("-")
        require(record["tag"] == TAG, "Wrong release tag")
        require(record["driver"] == driver and record["page_size"] == page, "Wrong driver/page mapping")
        require(record["kernel_release"] == "6.17.13-talos-dgx1022.6-" + page, "Wrong kernel release")
        require(record["talos_version"] == "v1.14.1" and record["talos_commit"] == TALOS_COMMIT, "Wrong Talos pin")
        require(record["nvidia_version"] == "580.178.04" and record["gds_version"] == "2.29.4", "Wrong driver pins")
        require(record["driver_source_directory"] == ("kernel-open" if driver == "open" else "kernel"), "Wrong driver source")
        require(record["kernel_config_sha256"] == sha(ROOT / ("kernel/config-" + page)), "Config provenance differs from release source")
        require(set(record["patches"]) == (set(PATCHES) if driver == "open" else set()), "Required open patches missing")
        for name, digest in record["patches"].items():
            require(digest == sha(ROOT / "extension/patches" / name), "Patch provenance differs from release source")
        require(set(record["artifacts"]) == set(artifact_names(variant)), "Wrong artifact filenames")
        for digest in record["artifacts"].values():
            require(re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid artifact checksum")
        require(re.fullmatch(r"[0-9a-f]{64}", record["module_signing_certificate_sha256"]), "Invalid certificate ID")
    for field in ("kernel_oci_digest", "kernel_build_fingerprint", "kernel_config_sha256", "installer_base_oci_digest"):
        require(records[0][field] == records[1][field], "4 KiB variants did not share " + field)
    require(records[1]["kernel_oci_digest"] != records[2]["kernel_oci_digest"], "Kernel geometries collided")
    require(records[1]["patches"] == records[2]["patches"], "Open variants use different patches")
    for field in ("module_signing_certificate_sha256", "source_commit", "dispram_oci_digest"):
        require(len({r[field] for r in records}) == 1, "Variants differ in " + field)


def oci_lines(records):
    digests = {}
    for r in records:
        page, variant = r["page_size"], r["variant"]
        digests["kernels/" + page] = r["kernel_oci_digest"]
        digests["talos/" + page + "/installer-base"] = r["installer_base_oci_digest"]
        digests["variants/" + variant + "/nvidia-extension"] = r["nvidia_oci_digest"]
        digests["common/dispram-extension"] = r["dispram_oci_digest"]
    return "".join(f"{digest}  {name}\n" for name, digest in sorted(digests.items()))


def finalize(out):
    records = [json.loads((out / "variants" / variant / "provenance.json").read_text()) for variant in VARIANTS]
    validate_records(records)
    for record in records:
        for name, checksum in record["artifacts"].items():
            require(sha(out / name) == checksum, "Artifact changed after packaging: " + name)
    save(out / "VARIANTS.json", {"schema_version": 1, "tag": TAG, "variants": records, "boot_tested": False})
    (out / "OCI-DIGESTS").write_text(oci_lines(records))
    files = sorted([name for variant in VARIANTS for name in artifact_names(variant)] + ["OCI-DIGESTS", "VARIANTS.json"])
    (out / "SHA256SUMS").write_text("".join(f"{sha(out / name)}  {name}\n" for name in files))


def verify(out, installers_only=False):
    sums = {}
    for line in (out / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ")
        require(name not in sums and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid or duplicate checksum")
        sums[name] = digest
    expected = {name for variant in VARIANTS for name in artifact_names(variant)} | {"OCI-DIGESTS", "VARIANTS.json"}
    require(set(sums) == expected, "Checksum manifest must cover exactly six artifacts and both metadata files")
    for name, digest in sums.items():
        if not (installers_only and name.endswith(".iso")):
            require(sha(out / name) == digest, "Checksum mismatch: " + name)
    manifest = json.loads((out / "VARIANTS.json").read_text())
    require(manifest["tag"] == TAG and manifest["schema_version"] == 1, "Wrong manifest tag/schema")
    records = manifest["variants"]
    validate_records(records)
    require((out / "OCI-DIGESTS").read_text() == oci_lines(records), "OCI manifest/provenance mismatch")
    for record in records:
        for name, digest in record["artifacts"].items():
            require(sums[name] == digest, "Provenance/checksum disagreement: " + name)
    return records


def main():
    command, directory, *args = sys.argv[1:]
    out = Path(directory)
    if command == "shared":
        save(out / "shared" / (page_of(args[0]) + ".json"), shared_identity(out, args[0]))
    elif command == "check-shared":
        check_shared(out, args[0])
    elif command == "variant":
        record_variant(out, args[0])
    elif command == "finalize":
        finalize(out)
    elif command == "verify":
        verify(out, installers_only=args == ["--installers-only"])
        print("Verified all three variants, shared 4 KiB kernel, and checksums" + (" (installer-only download)" if args else ""))
    elif command == "notes":
        records = verify(out)
        print(f"Talos v1.14.1 / NVIDIA 580.178.04 / GDS 2.29.4 — {TAG}\n")
        for r in records:
            print(f"- **{r['variant']}**: `{r['kernel_release']}`, `uname -v` `#{r['kernel_build_fingerprint']}`; image tag `{TAG}-{r['variant']}`.")
        print("\nOpen variants include HUB ATS and leaf-table packing patches. Packing is inert at 4 KiB.")
        print("No unsuffixed image alias. These are build outputs, not a boot or CUDA validation.\n")
        print("```\n" + (out / "SHA256SUMS").read_text() + (out / "OCI-DIGESTS").read_text() + "```")
    else:
        raise ValueError("Unknown artifact command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error)) from error
