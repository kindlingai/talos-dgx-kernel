#!/usr/bin/env python3
"""Publish all three verified installers; refuse to replace an existing digest."""
from pathlib import Path
import re
import subprocess
import sys
from artifacts import ROOT, TAG, VARIANTS, require, verify


def output(command):
    return subprocess.check_output(command, text=True).strip()


def publish(out, image, tag):
    require(tag == TAG, "This branch only publishes " + TAG)
    records = verify(out, installers_only=True)
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(all(record["source_commit"] == source for record in records), "Release source commit differs from checked-out source")
    # Preflight EVERY tag before any write; a conflict prevents partial publication.
    plan = []
    for variant in VARIANTS:
        archive = out / f"installer-arm64-{variant}.tar"
        expected = output(["crane", "digest", "--tarball", str(archive)])
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", expected), "Invalid local image digest")
        ref = f"{image}:{tag}-{variant}"
        existing = subprocess.run(["crane", "digest", ref], capture_output=True, text=True)
        if existing.returncode == 0:
            require(existing.stdout.strip() == expected, "Refusing to overwrite " + ref)
            present = True
        else:
            # Authentication, network, and unknown errors are not tag absence.
            require(any(code in existing.stderr for code in ("MANIFEST_UNKNOWN", "NAME_UNKNOWN")),
                    "Cannot determine whether tag exists: " + ref + "\n" + existing.stderr)
            present = False
        plan.append((variant, archive, ref, expected, present))
    refs = []
    for variant, archive, ref, expected, present in plan:
        if not present:
            subprocess.run(["crane", "push", str(archive), ref], check=True)
        require(output(["crane", "digest", ref]) == expected, "Published digest mismatch: " + ref)
        refs.append(f"{variant}  {ref}@{expected}")
    (out / "INSTALLER-REFS").write_text("\n".join(refs) + "\n")
    print("\n".join(refs))


if __name__ == "__main__":
    try:
        publish(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
