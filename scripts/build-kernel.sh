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
# BuildKit secrets do not participate in cache keys. Match the explicit public ID.
test "$("$(dirname "$0")/signing-key-id.sh" /run/secrets/module_signing_key)" = "${MODULE_SIGNING_CERT_SHA256:?}"
: "${THINLTO_CACHE_DIR:?}"
echo "ThinLTO cache before: $(du -sh "${THINLTO_CACHE_DIR}")"

# CONFIG is the complete olddefconfig output for this toolchain.
cp "${config}" .config
make olddefconfig
cmp .config "${config}"
test "$(make -s kernelrelease)" = "${KERNEL_RELEASE}"

export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S +0000')

# make and ThinLTO share the job count. pahole runs single-threaded (JOBS=1),
# which keeps BTF type order stable between builds.
kmake=(make -j"${jobs}" LD="ld.lld --thinlto-jobs=${jobs} --threads=${jobs} --thinlto-cache-dir=${THINLTO_CACHE_DIR}" JOBS=1)

"${kmake[@]}" vmlinuz.efi modules
echo "ThinLTO cache after: $(du -sh "${THINLTO_CACHE_DIR}")"
# modules_install strips each module, then signs it with CONFIG_MODULE_SIG_KEY.
"${kmake[@]}" modules_install INSTALL_MOD_PATH="${rootfs}/usr" INSTALL_MOD_STRIP=1 DEPMOD=true
rm -f "${rootfs}/usr/lib/modules/${KERNEL_RELEASE}"/{build,source}

install -D -m 0644 arch/arm64/boot/vmlinuz.efi "${rootfs}/boot/vmlinuz"
install -D -m 0644 System.map "${rootfs}/boot/System.map"

"$(dirname "$0")/check-modules.sh" System.map "${rootfs}/usr"
