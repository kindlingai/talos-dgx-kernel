# Build graph for the kernel, the NVIDIA extension, and the Talos images that
# embed them. The Makefile sets the variables below and runs `kernel` before
# `talos`, because the Talos targets consume the exported kernel OCI layout.

variable "OUT" {
  description = "Absolute path of the output directory"
}

variable "TALOS_SRC" {
  description = "Absolute path of the patched Talos source checkout"
}

variable "TALOS_VERSION" {}
variable "TALOS_COMMIT" {}
variable "KERNEL_RELEASE" {
  validation {
    condition = KERNEL_RELEASE == "6.17.13-talos-dgx1022.10-${KERNEL_PAGE_SIZE}"
    error_message = "KERNEL_RELEASE must match the selected .10 page geometry"
  }
}
variable "KERNEL_CONFIG" {
  validation {
    condition = KERNEL_CONFIG == "kernel/config-${KERNEL_PAGE_SIZE}"
    error_message = "KERNEL_CONFIG must match the selected page geometry"
  }
}
variable "KERNEL_PAGE_SIZE" {
  validation {
    condition = contains(["4k", "64k"], KERNEL_PAGE_SIZE)
    error_message = "KERNEL_PAGE_SIZE must be 4k or 64k"
  }
}
variable "DRIVER_FLAVOR" {}
variable "VARIANT" {
  validation {
    condition = contains(["proprietary-4k", "open-4k", "open-64k"], VARIANT) && VARIANT == "${DRIVER_FLAVOR}-${KERNEL_PAGE_SIZE}"
    error_message = "Supported variants: proprietary-4k, open-4k, open-64k; driver/page must match"
  }
}
variable "SOURCE_DATE_EPOCH" {}

variable "SIGNING_KEY" {
  description = "PEM file holding the module signing private key and certificate"
}

variable "MODULE_SIGNING_CERT_SHA256" {}

variable "KBUILD_BUILD_VERSION" {
  description = "Fingerprint of the kernel build inputs, reported by `uname -v`"
}

# SOURCE_DATE_EPOCH sets image timestamps; rewrite-timestamp clamps file times.
target "_reproducible" {
  args = {
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
  }
  attest = [
    "type=provenance,disabled=true",
    "type=sbom,disabled=true",
  ]
}

target "_kernel" {
  inherits   = ["_reproducible"]
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/arm64"]
  args = {
    KERNEL_RELEASE       = KERNEL_RELEASE
    KERNEL_CONFIG        = KERNEL_CONFIG
    KERNEL_PAGE_SIZE     = KERNEL_PAGE_SIZE
    KBUILD_BUILD_VERSION = KBUILD_BUILD_VERSION
    MODULE_SIGNING_CERT_SHA256 = MODULE_SIGNING_CERT_SHA256
    NVIDIA_VERSION       = "580.178.04"
    GDS_VERSION          = "2.29.4"
  }
  secret = ["id=module_signing_key,src=${SIGNING_KEY}"]
}

target "kernel" {
  inherits = ["_kernel"]
  target   = "kernel"
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/kernels/${KERNEL_PAGE_SIZE}"]
}

target "nvidia-extension" {
  inherits = ["_kernel"]
  target   = "nvidia-extension"
  args = {
    DRIVER_FLAVOR = DRIVER_FLAVOR
    VARIANT       = VARIANT
    EXTENSION_NAME = DRIVER_FLAVOR == "open" ? "nvidia-open-gpu-kernel-modules-lts" : "nvidia-gpu-kernel-modules-lts"
  }
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/variants/${VARIANT}/nvidia-extension"]
}

target "dispram-extension" {
  inherits   = ["_reproducible"]
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/arm64"]
  args = {
    NVIDIA_VERSION = "580.178.04"
  }
  target   = "dispram-extension"
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/common/dispram-extension"]
}

target "toolkit-extension" {
  inherits   = ["_reproducible"]
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/arm64"]
  target     = "toolkit-extension"
  output     = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/common/toolkit-extension"]
}

# Talos's own Dockerfile, built with the arguments its Makefile passes at
# TALOS_COMMIT, package images pinned by digest, and PKG_KERNEL replaced by the
# kernel OCI layout.
target "_talos" {
  inherits   = ["_reproducible"]
  context    = TALOS_SRC
  dockerfile = "Dockerfile"
  contexts = {
    kernelcustom = "oci-layout://${OUT}/oci/kernels/${KERNEL_PAGE_SIZE}"
  }
  args = {
    ABBREV_TAG                   = TALOS_VERSION
    ARTIFACTS                    = "_out"
    CGO_ENABLED                  = "0"
    EMBED_TARGET                 = "embed"
    FACTORY                      = "factory.talos.dev"
    GO_BUILDFLAGS                = "-tags tcell_minimal,grpcnotrace"
    GO_BUILDFLAGS_TALOSCTL       = " -tags grpcnotrace"
    GO_LDFLAGS                   = "-s -w"
    GO_MACHINED_LDFLAGS          = "-X golang.zx2c4.com/wireguard/ipc.socketDirectory=/system/wireguard-sock "
    GOAMD64                      = "v2"
    GOFIPS140                    = "off"
    INSTALLER_ARCH               = "targetarch"
    MARKDOWNLINTCLI_VERSION      = "0.49.1"
    MICROSOFT_SECUREBOOT_RELEASE = "v1.1.3"
    NAME                         = "Talos"
    PKGS                         = "v1.14.0-48-gf4bda77"
    PKGS_PREFIX                  = "ghcr.io/siderolabs"
    REGISTRY                     = "ghcr.io"
    SHA                          = TALOS_COMMIT
    TAG                          = TALOS_VERSION
    TESTPKGS                     = "github.com/siderolabs/talos/..."
    TOOLS                        = "v1.14.0-11-g8dad45e@sha256:d072f2ea641b2e568db0110e1cbe936231fe56bfd3acbb37e139c3e3f715fb80"
    TOOLS_PREFIX                 = "ghcr.io/siderolabs/tools"
    UNITTEST_PARALLELISM         = "8"
    USERNAME                     = "siderolabs"
    ZSTD_COMPRESSION_LEVEL       = "18"
    http_proxy                   = ""
    https_proxy                  = ""

    PKG_KERNEL              = "kernelcustom"
    PKG_RASPBERYPI_FIRMWARE = ""
    PKG_U_BOOT              = ""
    PKG_APPARMOR            = "ghcr.io/siderolabs/apparmor:v1.14.0-48-gf4bda77@sha256:f2c99c336f1751269996aca2e71b86c447b0404e4c5fd93d2b2c8636fc85db9d"
    PKG_BTRFSPROGS          = "ghcr.io/siderolabs/btrfsprogs:v1.14.0-48-gf4bda77@sha256:48b212ab61229698bef037c449f0511a90a01389deb8a57a21a64bf2be5bb222"
    PKG_CA_CERTIFICATES     = "ghcr.io/siderolabs/ca-certificates:v1.14.0-48-gf4bda77@sha256:69afca74404f025e342f9b834f345318bd8a333c25cb2a774c3fe80901fdf4ef"
    PKG_CNI                 = "ghcr.io/siderolabs/cni:v1.14.0-48-gf4bda77@sha256:7f94e68990902469b2a72f03794329695b0c9733debb5bbef2361bee6e045c82"
    PKG_CONTAINERD          = "ghcr.io/siderolabs/containerd:v1.14.0-48-gf4bda77@sha256:28ccc245d62c7225e69362cd2d8a2c9127118f6aa53659538ec132eb137411a5"
    PKG_CPIO                = "ghcr.io/siderolabs/cpio:v1.14.0-48-gf4bda77@sha256:b87e48517a8b30ab1ef7d191c45abf0a44aa004a5eff5c71e3e8b5868f86ce47"
    PKG_CRYPTSETUP          = "ghcr.io/siderolabs/cryptsetup:v1.14.0-48-gf4bda77@sha256:d62f5ef7ab7c5c11e1435baa3e866e27bb538640b197f62cbe0a3d0d73747510"
    PKG_DOSFSTOOLS          = "ghcr.io/siderolabs/dosfstools:v1.14.0-48-gf4bda77@sha256:382c859ae3df025225bda6bbf3bb0561def674d9f2fa995fd116250357d8380e"
    PKG_E2FSPROGS           = "ghcr.io/siderolabs/e2fsprogs:v1.14.0-48-gf4bda77@sha256:7e05359f680c89649e9a276a552993e7f7b0259ee5d26940ba443cb915044cb7"
    PKG_FHS                 = "ghcr.io/siderolabs/fhs:v1.14.0-48-gf4bda77@sha256:aa038d38eab4c3787a86d3ada41efd90405bcc32d45d73289b70f2dab235a19f"
    PKG_FLANNEL_CNI         = "ghcr.io/siderolabs/flannel-cni:v1.14.0-48-gf4bda77@sha256:996180e1d0b0cf08ae869525d0782363e78b6634df14a3b592d168b792e94ca3"
    PKG_GLIB                = "ghcr.io/siderolabs/glib:v1.14.0-48-gf4bda77@sha256:c41bbd2734d86a7c523689655da853d347d3f0d35e7c5d36a0c5696038431e29"
    PKG_GRUB                = "ghcr.io/siderolabs/grub:v1.14.0-48-gf4bda77@sha256:39472eeb6c033ae258ad4ec11f066e7ab320b1fc3aa56cc612c02ea4e8476b85"
    PKG_IGZIP               = "ghcr.io/siderolabs/igzip:v1.14.0-48-gf4bda77@sha256:1abdc05ce2a8cd641a1d9780eb813cb5cee4875c208be15799ed72f9b3fcdc48"
    PKG_IPTABLES            = "ghcr.io/siderolabs/iptables:v1.14.0-48-gf4bda77@sha256:463d45acdc06029dacc57c3de6609944c044ddae690e78beb07746fb8922dbb7"
    PKG_IPXE                = "ghcr.io/siderolabs/ipxe:v1.14.0-48-gf4bda77@sha256:af7909795d0c8bd173cf18dea46cdb1d650bc06c358879e03bb7ff462c5c1fb2"
    PKG_KMOD                = "ghcr.io/siderolabs/kmod:v1.14.0-48-gf4bda77@sha256:43315cb342506a4ed2330618cfdfb38562ce8cfb94079c357a34217708ec58b1"
    PKG_LIBAIO              = "ghcr.io/siderolabs/libaio:v1.14.0-48-gf4bda77@sha256:55c2ccff11c56d48ef6c06880e1b032d55aaf2b22704d59e590294b5ca7129fe"
    PKG_LIBARCHIVE          = "ghcr.io/siderolabs/libarchive:v1.14.0-48-gf4bda77@sha256:ca022570de52b18fd11aecd2e2a5d369e33e107eec97f7fcbc0ba2ebb23a1502"
    PKG_LIBATTR             = "ghcr.io/siderolabs/libattr:v1.14.0-48-gf4bda77@sha256:52a23a35a95e73bcfa76411ddc1b04ec71d34b74be11fe6b88f163f17a03bae0"
    PKG_LIBBURN             = "ghcr.io/siderolabs/libburn:v1.14.0-48-gf4bda77@sha256:74512b082b84d7bc33e4a45b02a840229a41c8cc80923094fb4e5499d5ab04a6"
    PKG_LIBCAP              = "ghcr.io/siderolabs/libcap:v1.14.0-48-gf4bda77@sha256:a80187bb419e7f17c259eb89796883d661093ca102888845833b20997e2951b4"
    PKG_LIBINIH             = "ghcr.io/siderolabs/libinih:v1.14.0-48-gf4bda77@sha256:f73e40a482cd7833697456405a4bac13464fcbd83a49ec14f90b3a14a833301c"
    PKG_LIBISOBURN          = "ghcr.io/siderolabs/libisoburn:v1.14.0-48-gf4bda77@sha256:168b4713681b48e9e9e6be0e7f42efd9995a1649904ba94fb18e1891bc7a2f65"
    PKG_LIBISOFS            = "ghcr.io/siderolabs/libisofs:v1.14.0-48-gf4bda77@sha256:d2a67ef6b6df637b9579c605ab78f95abeaf3c58befd7b94d7b5cf3e688951e2"
    PKG_LIBJANSSON          = "ghcr.io/siderolabs/libjansson:v1.14.0-48-gf4bda77@sha256:aeef64a3a549e59c799f115e21ca0aad7f4164e53e88d2a8cf6e67e62afeae0c"
    PKG_LIBJSON_C           = "ghcr.io/siderolabs/libjson-c:v1.14.0-48-gf4bda77@sha256:dbabf78d995fb7a8a59ec9953ff693a4d38bd298ad791d7474eb94fe9e4d45c8"
    PKG_LIBLZMA             = "ghcr.io/siderolabs/liblzma:v1.14.0-48-gf4bda77@sha256:49a26433b0d7214750e24063da268553fcb25ae22eec372e1226d994552edb67"
    PKG_LIBMNL              = "ghcr.io/siderolabs/libmnl:v1.14.0-48-gf4bda77@sha256:87eb1954d777d6365ed3520b51d7827f675275027f5b294249d4f3ffe3d73e2d"
    PKG_LIBNFTNL            = "ghcr.io/siderolabs/libnftnl:v1.14.0-48-gf4bda77@sha256:c21bd3d82801b380038ef880e57653cbce8a2e3aeef7d8c4578b0dc67dc62167"
    PKG_LIBPOPT             = "ghcr.io/siderolabs/libpopt:v1.14.0-48-gf4bda77@sha256:77207d245f76d3734334c190ced0f9f825036677585e2443a7ef7c80da51e23a"
    PKG_LIBSELINUX          = "ghcr.io/siderolabs/libselinux:v1.14.0-48-gf4bda77@sha256:611407b679dc68f999e997543ed1a9e5a1124b725341f83ccb77da22a11e8b0e"
    PKG_LIBSEPOL            = "ghcr.io/siderolabs/libsepol:v1.14.0-48-gf4bda77@sha256:e8793c6bbeb9c7dde25e2cfc975e8f22a110784aa33ed2561257f7f7e6a792d7"
    PKG_LIBUCONTEXT         = "ghcr.io/siderolabs/libucontext:v1.14.0-48-gf4bda77@sha256:656ca60b1e5e2e2b7454a8ad4fea75799615aa7d7996d2bf767b613e8343cb01"
    PKG_LIBURCU             = "ghcr.io/siderolabs/liburcu:v1.14.0-48-gf4bda77@sha256:62a4c7c43310e84b10834222b5906adb3ad7aef0f648087926315af68ff0eccd"
    PKG_LINUX_FIRMWARE      = "ghcr.io/siderolabs/linux-firmware:v1.14.0-48-gf4bda77@sha256:f5aace37c291a293eb5ff3f6511bdea503cbd60ecc38e919b0093a2aca4cfb15"
    PKG_LVM2                = "ghcr.io/siderolabs/lvm2:v1.14.0-48-gf4bda77@sha256:3deb2da8e461d80e0b324cc30933dad691fcd520f56a772f8f97ae540185d28a"
    PKG_MDADM               = "ghcr.io/siderolabs/mdadm-pkg:v1.14.0-48-gf4bda77@sha256:f147f75dbe4b73d897d5cb0d231d040654c4bd048219024160cb076088fc4ea0"
    PKG_MTOOLS              = "ghcr.io/siderolabs/mtools:v1.14.0-48-gf4bda77@sha256:f45317e753c05eb720390de05fbf24242fecd02def453dddb796bb194b2122f9"
    PKG_MUSL                = "ghcr.io/siderolabs/musl:v1.14.0-48-gf4bda77@sha256:923fade375b8b7a61f3c931287e4b9111339ffb1f87fd0cc359c0067805d45e6"
    PKG_NFTABLES            = "ghcr.io/siderolabs/nftables:v1.14.0-48-gf4bda77@sha256:f54852e99ff73f39af7af77d30c78deaa148c3dab4d8fc9a1938e02763ce078f"
    PKG_OPENSSL             = "ghcr.io/siderolabs/openssl:v1.14.0-48-gf4bda77@sha256:ff33fc2737acfd82527180a4278316670f18c3996cada42e499f7e6c6739a400"
    PKG_OPEN_VMDK           = "ghcr.io/siderolabs/open-vmdk:v1.14.0-48-gf4bda77@sha256:12009662fd636cc303e3211321c11554cae79dd5e9cd7358733731bd67e35c8c"
    PKG_PCRE2               = "ghcr.io/siderolabs/pcre2:v1.14.0-48-gf4bda77@sha256:71b28ec0e8df5b8b565e25ad17d12f7172f322416f4b0ce52b13995ebc8bd6ca"
    PKG_PIGZ                = "ghcr.io/siderolabs/pigz:v1.14.0-48-gf4bda77@sha256:73447910c8beea9963ec8f7230fc772036cbdadb6259b12d6128e6cee99e3c7c"
    PKG_QEMU_TOOLS          = "ghcr.io/siderolabs/qemu-tools:v1.14.0-48-gf4bda77@sha256:a54a15feff6e817da6134189bca3f42e288d1be0819a0972a2d422cdf9e9f980"
    PKG_RUNC                = "ghcr.io/siderolabs/runc:v1.14.0-48-gf4bda77@sha256:8da9b4fe7aa1408965a39c870baeb96ec0d3f4c74f6aaa50d94957b76510a348"
    PKG_SD_BOOT             = "ghcr.io/siderolabs/sd-boot:v1.14.0-48-gf4bda77@sha256:b18008c453500d893adc3711ed891b23c56fe21080251d49744095dcc73a9e48"
    PKG_SQUASHFS_TOOLS      = "ghcr.io/siderolabs/squashfs-tools:v1.14.0-48-gf4bda77@sha256:ffe9c49b6d50265fcb6e49b2f5f01eb6e00b50307340811369fe79ec941dd14b"
    PKG_SYSTEMD_UDEVD       = "ghcr.io/siderolabs/systemd-udevd:v1.14.0-48-gf4bda77@sha256:097b0390d952928d243d0a131bc0da4ee7d1445b56aad8ecb4302093be9424f6"
    PKG_TALOSCTL_CNI_BUNDLE = "ghcr.io/siderolabs/talosctl-cni-bundle:v1.14.0-48-gf4bda77@sha256:e09f506e5b805aab72883b9d9df188d0cb4aaea00ecd5531ec393e79a255df17"
    PKG_TAR                 = "ghcr.io/siderolabs/tar:v1.14.0-48-gf4bda77@sha256:d908e6e40992dbb4e4270471416ddc7ccb06fa71dd8172ba6e3c347c74a41092"
    PKG_UTIL_LINUX          = "ghcr.io/siderolabs/util-linux:v1.14.0-48-gf4bda77@sha256:64b3a55ad943a7fde06218157670397356bde56f02986ee2cbe78fba793e672e"
    PKG_XFSPROGS            = "ghcr.io/siderolabs/xfsprogs:v1.14.0-48-gf4bda77@sha256:ea25b1727a6ac0be034e002c9e621d7c8da9f2f8f1213bb8d6d5ecbbd7596bc5"
    PKG_XZ                  = "ghcr.io/siderolabs/xz:v1.14.0-48-gf4bda77@sha256:dbf71f3a44f94760a4bbded6c64253aa53c20c7d2c8264f050d39a9426d50712"
    PKG_ZLIB                = "ghcr.io/siderolabs/zlib:v1.14.0-48-gf4bda77@sha256:3b0542d4d046908bcce040d9f361196a6a935582807af44ecc86cf00c461b6e7"
    PKG_ZSTD                = "ghcr.io/siderolabs/zstd:v1.14.0-48-gf4bda77@sha256:01d35cc6d4f3d1d4f9ee712844e23cb06fa95d71025842db646e98c86190db92"
  }
}

target "installer-base" {
  inherits  = ["_talos"]
  target    = "installer-base"
  platforms = ["linux/arm64"]
  output    = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/talos/${KERNEL_PAGE_SIZE}/installer-base"]
}

# The imager runs on the build host and carries the arm64 kernel and initramfs.
target "imager" {
  inherits = ["_talos"]
  target   = "imager"
  args = {
    INSTALLER_ARCH = "arm64"
  }
  tags   = ["talos-dgx-kernel/imager:${TALOS_VERSION}-${KERNEL_PAGE_SIZE}"]
  output = ["type=docker,rewrite-timestamp=true"]
}

group "talos" {
  targets = ["installer-base", "imager"]
}
