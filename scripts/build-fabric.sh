#!/bin/bash
# Builds sparkos-fabric as a static executable and assembles the sparkos-fabric
# system extension in EXTENSION:
#   EXTENSION/manifest.yaml
#   EXTENSION/rootfs/usr/local/etc/containers/sparkos-fabric.yaml   service definition
#   EXTENSION/rootfs/usr/local/lib/containers/sparkos-fabric/       service root filesystem
#
# Usage: build-fabric.sh SOURCE EXTENSION
set -euo pipefail

source=$1
extension=$2
service=${extension}/rootfs/usr/local/lib/containers/sparkos-fabric

# The service root filesystem holds the executable and the mount points of the
# container's default mounts; Talos mounts it read-only.
mkdir -p "${service}"/{dev,proc,sys,run}
gcc -std=gnu11 -O2 -Wall -Wextra -Werror -static -s \
    "${source}/sparkos-fabric.c" -o "${service}/sparkos-fabric"

install -D -m 0644 "${source}/manifest.yaml" "${extension}/manifest.yaml"
install -D -m 0644 "${source}/sparkos-fabric.yaml" "${extension}/rootfs/usr/local/etc/containers/sparkos-fabric.yaml"
install -D -m 0644 "${source}/LICENSE" "${extension}/rootfs/usr/local/share/licenses/sparkos-fabric/LICENSE"
