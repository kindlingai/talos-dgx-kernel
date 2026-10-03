#!/bin/bash
# Builds NVIDIA GPU modules (kernel-open/ or kernel/ in the driver archive)
# and GPUDirect Storage (nvidia-fs) against the kernel tree in /src/linux, and
# installs them, signed, into EXTENSION_ROOTFS/usr/lib/modules/RELEASE/extras
# together with the kernel's module metadata from KERNEL_ROOTFS.
#
# Usage: build-nvidia.sh DOWNLOADS PATCHES KERNEL_ROOTFS EXTENSION_ROOTFS
# Environment: KERNEL_RELEASE, DRIVER_FLAVOR, KERNEL_PAGE_SIZE, MODULE_SIGNING_CERT_SHA256
#
# PATCHES/series lists patches to the driver archive, applied in order with -p1.
set -euo pipefail

downloads=$1
patches=$2
kernel_rootfs=$3
rootfs=$4
jobs=$(nproc)
linux=/src/linux
nvidia_src=/src/nvidia
gds_src=/src/gds
modules=usr/lib/modules/${KERNEL_RELEASE}
"$(dirname "$0")/validate-variant.sh" "${DRIVER_FLAVOR}" "${KERNEL_PAGE_SIZE}"
test "$("$(dirname "$0")/signing-key-id.sh" /run/secrets/module_signing_key)" = "${MODULE_SIGNING_CERT_SHA256:?}"
case "${DRIVER_FLAVOR}" in
    open) driver_dir=kernel-open ;;
    proprietary) driver_dir=kernel ;;
esac
case "${KERNEL_PAGE_SIZE}" in
    4k) grep -qx 'CONFIG_ARM64_4K_PAGES=y' "${linux}/.config" ;;
    64k) grep -qx 'CONFIG_ARM64_64K_PAGES=y' "${linux}/.config" ;;
esac

mkdir -p "${nvidia_src}" "${gds_src}"
tar -xJf "${downloads}/nvidia.tar.xz" -C "${nvidia_src}" --strip-components=1 --no-same-owner
tar -xzf "${downloads}/gds.tar.gz" -C "${gds_src}" --strip-components=1 --no-same-owner

if [[ ${DRIVER_FLAVOR} == open ]]; then
    # Both fixes are mandatory for BOTH open variants; packing is inert at 4 KiB.
    cmp "${patches}/series" <(printf '%s\n' \
        0001-nvidia-uvm-flush-gpu-tlb-after-hub-ats-faults.patch \
        0002-nvidia-uvm-pack-user-leaf-page-tables.patch)
    while read -r name; do
        echo "Applying ${name}"
        patch -d "${nvidia_src}" -p1 --batch --forward --fuzz=0 --quiet < "${patches}/${name}"
    done < "${patches}/series"
fi

# NVIDIA and GDS conftests call the compiler directly, so CC carries the target.
cc="clang --target=aarch64-linux-musl"
lld="ld.lld --thinlto-jobs=${jobs} --threads=${jobs}"
install=(INSTALL_MOD_PATH="${rootfs}/usr" INSTALL_MOD_DIR=extras INSTALL_MOD_STRIP=1 DEPMOD=true)

nvidia=(make -C "${nvidia_src}/${driver_dir}" -j"${jobs}" CC="${cc}" LD="${lld}" OBJDUMP=llvm-objdump JOBS=1
    SYSSRC="${linux}" SYSOUT="${linux}")
"${nvidia[@]}"
"${nvidia[@]}" modules_install "${install[@]}"

# GDS configure locates the kernel tree through /lib/modules/RELEASE/build.
mkdir -p "/lib/modules/${KERNEL_RELEASE}"
ln -sfn "${linux}" "/lib/modules/${KERNEL_RELEASE}/build"
cd "${gds_src}/src"
CC="${cc}" ./configure "${KERNEL_RELEASE}"
gds=(make -C "${linux}" M="${gds_src}/src" -j"${jobs}" LD="${lld}" JOBS=1)
"${gds[@]}" modules KDIR="${linux}" \
    NVIDIA_SRC_DIR="${nvidia_src}/${driver_dir}/nvidia" \
    KBUILD_EXTRA_SYMBOLS="${nvidia_src}/${driver_dir}/Module.symvers" \
    KCPPFLAGS="-DCONFIG_NVFS_STATS=y -DGDS_VERSION=$(<GDS_VERSION) -DNVFS_ENABLE_KERN_RDMA_SUPPORT -DNVFS_BATCH_SUPPORT=y" \
    KCFLAGS=-Wno-strict-prototypes CONFIG_NVFS_STATS=y CONFIG_NVFS_BATCH_SUPPORT=y
"${gds[@]}" modules_install "${install[@]}"

# Talos extensions carry the kernel's module metadata alongside their modules.
cp "${kernel_rootfs}/${modules}"/modules.{order,builtin,builtin.modinfo} "${rootfs}/${modules}/"
