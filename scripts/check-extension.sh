#!/bin/bash
# Checks the assembled NVIDIA system extension in EXTENSION:
#   - extras/ holds the six NVIDIA and GDS modules
#   - the modules resolve against the kernel in KERNEL_ROOTFS (check-modules.sh)
#   - the layout passes the Talos extensions validator
#
# Usage: check-extension.sh KERNEL_ROOTFS EXTENSION
# Environment: KERNEL_RELEASE, DRIVER_FLAVOR
set -euo pipefail

kernel_rootfs=$1
extension=$2
modules=usr/lib/modules/${KERNEL_RELEASE}

expected="nvidia-drm.ko nvidia-fs.ko nvidia-modeset.ko nvidia-peermem.ko nvidia-uvm.ko nvidia.ko"
actual=$(cd "${extension}/rootfs/${modules}/extras" && ls | sort | xargs)
if [[ ${actual} != "${expected}" ]]; then
    echo "extras/ holds '${actual}', expected '${expected}'" >&2
    exit 1
fi

combined=$(mktemp -d)
cp -a "${kernel_rootfs}/usr/lib" "${combined}/"
cp -a "${extension}/rootfs/${modules}/extras" "${combined}/lib/modules/${KERNEL_RELEASE}/"
"$(dirname "$0")/check-modules.sh" "${kernel_rootfs}/boot/System.map" "${combined}"
rm -rf "${combined}"

case "${DRIVER_FLAVOR:?}" in
    open) package=nvidia-open-gpu-kernel-modules-lts ;;
    proprietary) package=nvidia-gpu-kernel-modules-lts ;;
    *) exit 1 ;;
esac
extensions-validator validate --rootfs="${extension}" --pkg-name="${package}"
