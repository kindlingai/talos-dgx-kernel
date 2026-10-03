#!/usr/bin/env python3
"""Hash only the Linux compilation inputs, not module or imager packaging."""
import hashlib
from pathlib import Path
import sys


def fingerprint(root, config):
    dockerfile = (root / "Dockerfile").read_text()
    compile_stages = dockerfile.split("# BEGIN KERNEL INPUTS\n", 1)[1].split("# END KERNEL INPUTS", 1)[0]
    digest = hashlib.sha256()
    # Include the frontend pin, which can affect execution, but not other stages.
    digest.update((dockerfile.splitlines()[0] + "\n" + compile_stages).encode())
    paths = [config, "scripts/kernel-fingerprint.py", "scripts/prepare-linux.sh",
             "scripts/build-kernel.sh", "scripts/check-modules.sh", "scripts/signing-key-id.sh"]
    paths += [str(path.relative_to(root)) for path in sorted((root / "kernel/patches").iterdir()) if path.is_file()]
    for name in paths:
        digest.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
    return digest.hexdigest()[:12]


if __name__ == "__main__":
    print(fingerprint(Path(__file__).resolve().parent.parent, sys.argv[1]))
