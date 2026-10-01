#!/bin/bash
# Unpacks the Ubuntu linux-nvidia-6.17 source into the current directory, then
# applies the Ubuntu diff and the patches listed in PATCHES/series, in order.
#
# Usage: prepare-linux.sh DOWNLOADS PATCHES
set -euo pipefail

downloads=$1
patches=$2

tar -xzf "${downloads}/linux.tar.gz" --strip-components=1 --no-same-owner
patch -p1 --batch --forward --fuzz=0 --quiet < "${downloads}/linux-nvidia.diff"

while read -r name; do
    echo "Applying ${name}"
    patch -p1 --batch --forward --fuzz=0 --quiet < "${patches}/${name}"
done < "${patches}/series"

# The Ubuntu diff adds the Debian module signing hook as a regular file.
chmod +x debian/scripts/sign-module
