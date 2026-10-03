#!/usr/bin/env python3
"""Render only supported variant paths into pinned Talos imager profiles."""
from pathlib import Path
import sys
from artifacts import VARIANTS

kind, variant = sys.argv[1:]
if kind not in ("installer", "iso") or variant not in VARIANTS:
    raise SystemExit("Unsupported profile or variant")
root = Path(__file__).resolve().parents[1]
text = (root / "talos" / (kind + ".yaml")).read_text()
print(text.replace("@VARIANT@", variant).replace("@PAGE@", variant.split("-")[1]), end="")
