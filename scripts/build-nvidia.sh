#!/bin/bash
# Builds the NVIDIA proprietary driver modules and GPUDirect Storage (nvidia-fs)
# against the kernel tree in /src/linux and installs them, signed, into
# EXTENSION_ROOTFS/usr/lib/modules/RELEASE/extras together with the kernel's
# module metadata from KERNEL_ROOTFS.
#
# Usage: build-nvidia.sh DOWNLOADS KERNEL_ROOTFS EXTENSION_ROOTFS
# Environment: KERNEL_RELEASE, JOBS (default: nproc)
set -euo pipefail

downloads=$1
kernel_rootfs=$2
rootfs=$3
jobs=${JOBS:-$(nproc)}
linux=/src/linux
nvidia_src=/src/nvidia
gds_src=/src/gds
modules=usr/lib/modules/${KERNEL_RELEASE}

mkdir -p "${nvidia_src}" "${gds_src}"
tar -xJf "${downloads}/nvidia.tar.xz" -C "${nvidia_src}" --strip-components=1 --no-same-owner
tar -xzf "${downloads}/gds.tar.gz" -C "${gds_src}" --strip-components=1 --no-same-owner

# NVIDIA and GDS conftests call the compiler directly, so CC carries the target.
cc="clang --target=aarch64-linux-musl"
lld="ld.lld --thinlto-jobs=${jobs} --threads=${jobs}"
install=(INSTALL_MOD_PATH="${rootfs}/usr" INSTALL_MOD_DIR=extras INSTALL_MOD_STRIP=1 DEPMOD=true)

nvidia=(make -C "${nvidia_src}/kernel" -j"${jobs}" CC="${cc}" LD="${lld}" OBJDUMP=llvm-objdump JOBS=1
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
    NVIDIA_SRC_DIR="${nvidia_src}/kernel/nvidia" \
    KBUILD_EXTRA_SYMBOLS="${nvidia_src}/kernel/Module.symvers" \
    KCPPFLAGS="-DCONFIG_NVFS_STATS=y -DGDS_VERSION=$(<GDS_VERSION) -DNVFS_ENABLE_KERN_RDMA_SUPPORT -DNVFS_BATCH_SUPPORT=y" \
    KCFLAGS=-Wno-strict-prototypes CONFIG_NVFS_STATS=y CONFIG_NVFS_BATCH_SUPPORT=y
"${gds[@]}" modules_install "${install[@]}"

# Talos extensions carry the kernel's module metadata alongside their modules.
cp "${kernel_rootfs}/${modules}"/modules.{order,builtin,builtin.modinfo} "${rootfs}/${modules}/"
