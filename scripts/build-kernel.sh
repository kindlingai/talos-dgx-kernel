#!/bin/bash
# Builds the kernel source in the current directory and installs it into ROOTFS
# using the layout of a Talos PKG_KERNEL image:
#   ROOTFS/boot/vmlinuz              EFI zboot image
#   ROOTFS/boot/System.map
#   ROOTFS/usr/lib/modules/RELEASE   stripped, signed modules
#
# Usage: build-kernel.sh CONFIG ROOTFS
# Environment: KERNEL_RELEASE, SOURCE_DATE_EPOCH, KBUILD_BUILD_VERSION
set -euo pipefail

config=$1
rootfs=$2
jobs=$(nproc)

# CONFIG is the complete olddefconfig output for this toolchain.
cp "${config}" .config
make olddefconfig
cmp .config "${config}"
test "$(make -s kernelrelease)" = "${KERNEL_RELEASE}"

export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S +0000')

# make and ThinLTO share the job count. pahole runs single-threaded (JOBS=1),
# which keeps BTF type order stable between builds.
kmake=(make -j"${jobs}" LD="ld.lld --thinlto-jobs=${jobs} --threads=${jobs}" JOBS=1)

"${kmake[@]}" vmlinuz.efi modules
# modules_install strips each module, then signs it with CONFIG_MODULE_SIG_KEY.
"${kmake[@]}" modules_install INSTALL_MOD_PATH="${rootfs}/usr" INSTALL_MOD_STRIP=1 DEPMOD=true
rm -f "${rootfs}/usr/lib/modules/${KERNEL_RELEASE}"/{build,source}

install -D -m 0644 arch/arm64/boot/vmlinuz.efi "${rootfs}/boot/vmlinuz"
install -D -m 0644 System.map "${rootfs}/boot/System.map"

"$(dirname "$0")/check-modules.sh" System.map "${rootfs}/usr"
