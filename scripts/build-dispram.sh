#!/bin/bash
# Builds dispramd as a static executable against the RM API headers of
# NVIDIA_VERSION and assembles the dispram system extension in EXTENSION:
#   EXTENSION/manifest.yaml
#   EXTENSION/rootfs/usr/local/etc/containers/dispramd.yaml   service definition
#   EXTENSION/rootfs/usr/local/lib/containers/dispramd/       service root filesystem
#
# Usage: build-dispram.sh DOWNLOADS SOURCE EXTENSION
# Environment: NVIDIA_VERSION
set -euo pipefail

downloads=$1
source=$2
extension=$3
headers=/src/open-gpu-kernel-modules
service=${extension}/rootfs/usr/local/lib/containers/dispramd

# dispramd uses the RM SDK headers and the Unix ioctl definitions.
mkdir -p "${headers}"
tar -xzf "${downloads}/open-gpu-kernel-modules.tar.gz" -C "${headers}" --strip-components=1 \
    "open-gpu-kernel-modules-${NVIDIA_VERSION}/src/common/sdk/nvidia/inc" \
    "open-gpu-kernel-modules-${NVIDIA_VERSION}/kernel-open/common/inc" \
    "open-gpu-kernel-modules-${NVIDIA_VERSION}/src/nvidia/arch/nvalloc/unix/include"

# The service root filesystem holds the executable and the mount points of
# dispramd.yaml; Talos mounts it read-only.
mkdir -p "${service}"/{dev,proc,sys,run/dispram}
gcc -std=gnu11 -O2 -Wall -Wextra -Werror -static -s \
    -DNVIDIA_VERSION="\"${NVIDIA_VERSION}\"" \
    -I"${headers}/src/common/sdk/nvidia/inc" \
    -I"${headers}/kernel-open/common/inc" \
    -I"${headers}/src/nvidia/arch/nvalloc/unix/include" \
    "${source}/dispramd.c" -o "${service}/dispramd"

install -D -m 0644 "${source}/manifest.yaml" "${extension}/manifest.yaml"
install -D -m 0644 "${source}/dispramd.yaml" "${extension}/rootfs/usr/local/etc/containers/dispramd.yaml"
install -D -m 0644 "${source}/LICENSE" "${extension}/rootfs/usr/local/share/licenses/dispram/LICENSE"
