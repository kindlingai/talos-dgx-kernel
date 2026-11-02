#!/bin/bash
# Unpacks Linux into the current directory, applies the Talos kernel patches in
# name order exactly as siderolabs/pkgs kernel-build does (GNU patch, default
# fuzz), then our patches in PATCHES with --fuzz=0.
#
# Usage: prepare-linux.sh DOWNLOADS PATCHES
set -euo pipefail

downloads=$1
patches=$2

tar -xJf "${downloads}/linux.tar.xz" --strip-components=1 --no-same-owner

for patch in $(find "${downloads}/talos-patches" -type f -name '*.patch' | sort); do
    echo "Applying Talos $(basename "${patch}")"
    patch -p1 --batch --forward --quiet < "${patch}"
done

shopt -s nullglob
for patch in "${patches}"/*.patch; do
    echo "Applying $(basename "${patch}")"
    patch -p1 --batch --forward --fuzz=0 --quiet < "${patch}"
done
