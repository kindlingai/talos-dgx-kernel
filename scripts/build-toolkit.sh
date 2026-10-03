#!/bin/bash
# Assembles the nvidia-container-toolkit-lts system extension in EXTENSION from the
# pinned upstream extension in UPSTREAM:
#   - replaces nvidia-persistenced-wrapper with SOURCE/nvidia-persistenced-wrapper.c
#   - applies SOURCE/*.patch to the extension rootfs, in order, with -p1
#   - replaces the manifest with SOURCE/manifest.yaml
#
# Usage: build-toolkit.sh UPSTREAM SOURCE EXTENSION
set -euo pipefail

upstream=$1
source=$2
extension=$3
containers=${extension}/rootfs/usr/local/etc/containers

cp -a "${upstream}/." "${extension}/"

# The wrapper relies on this service definition: entrypoint, host /run as
# /var/run, and restart on exit.
grep -qx '  entrypoint: /usr/local/bin/nvidia-persistenced-wrapper' "${containers}/nvidia-persistenced.yaml"
grep -qx '      destination: /var/run' "${containers}/nvidia-persistenced.yaml"
grep -qx 'restart: always' "${containers}/nvidia-persistenced.yaml"

gcc -std=gnu11 -O2 -Wall -Wextra -Werror -static -s \
    "${source}/nvidia-persistenced-wrapper.c" -o "${extension}/rootfs/usr/local/bin/nvidia-persistenced-wrapper"

for patch in "${source}"/*.patch; do
    echo "Applying ${patch##*/}"
    patch -d "${extension}/rootfs" -p1 --batch --forward --fuzz=0 --no-backup-if-mismatch --quiet < "${patch}"
done

install -m 0644 "${source}/manifest.yaml" "${extension}/manifest.yaml"
