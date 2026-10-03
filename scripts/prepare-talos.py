#!/usr/bin/env python3
"""Apply the page-dependent Talos constants after the common source patch."""
from pathlib import Path
import sys

source, release, page = sys.argv[1:]
if page not in ("4k", "64k") or release != "6.17.13-talos-dgx1022.6-" + page:
    raise SystemExit("Unsupported kernel release/page geometry")
constants = Path(source) / "pkg/machinery/constants/constants.go"
text = constants.read_text()
old = 'DefaultKernelVersion = "6.18.51-talos"'
if text.count(old) != 1:
    raise SystemExit("Unexpected upstream DefaultKernelVersion")
constant_text = text.replace(old, f'DefaultKernelVersion = "{release}"')
modules = Path(source) / "hack/modules-arm64.txt"
text = modules.read_text()
vmxnet3 = "kernel/drivers/net/vmxnet3/vmxnet3.ko\n"
if text.count(vmxnet3) != 1:
    raise SystemExit("Unexpected upstream vmxnet3 list entry")
constants.write_text(constant_text)
if page == "64k":
    modules.write_text(text.replace(vmxnet3, ""))
