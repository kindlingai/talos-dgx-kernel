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
    condition = KERNEL_RELEASE == "7.0.14-talos-dgx1019.1-${KERNEL_PAGE_SIZE}"
    error_message = "KERNEL_RELEASE must match the selected dgx1019.1 page geometry"
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
    LIBVIRT_SHA256               = "7ec1a04e7e4f4069353d4daac117bbe869287f5b202695de61fe1b079efb6cb6"
    LIBVIRT_VERSION              = "v12.7.0"
    MARKDOWNLINTCLI_VERSION      = "0.49.1"
    MICROSOFT_SECUREBOOT_RELEASE = "v1.1.3"
    NAME                         = "Talos"
    PKGS                         = "v1.15.0-alpha.0-62-g2c33dc1"
    PKGS_PREFIX                  = "ghcr.io/siderolabs"
    REGISTRY                     = "ghcr.io"
    SHA                          = TALOS_COMMIT
    TAG                          = TALOS_VERSION
    TESTPKGS                     = "github.com/siderolabs/talos/..."
    TOOLS                        = "v1.15.0-alpha.0-15-g2d70a26@sha256:92cf7385e9f0b24f7690217796f5646bb685b0a0423dd2ff5d4181330f8b1f26"
    TOOLS_PREFIX                 = "ghcr.io/siderolabs/tools"
    UNITTEST_PARALLELISM         = "8"
    USERNAME                     = "siderolabs"
    ZSTD_COMPRESSION_LEVEL       = "18"
    http_proxy                   = ""
    https_proxy                  = ""

    PKG_KERNEL              = "kernelcustom"
    PKG_RASPBERYPI_FIRMWARE = ""
    PKG_U_BOOT              = ""
    PKG_APPARMOR            = "ghcr.io/siderolabs/apparmor:v1.15.0-alpha.0-62-g2c33dc1@sha256:f2c99c336f1751269996aca2e71b86c447b0404e4c5fd93d2b2c8636fc85db9d"
    PKG_BTRFSPROGS          = "ghcr.io/siderolabs/btrfsprogs:v1.15.0-alpha.0-62-g2c33dc1@sha256:48b212ab61229698bef037c449f0511a90a01389deb8a57a21a64bf2be5bb222"
    PKG_CA_CERTIFICATES     = "ghcr.io/siderolabs/ca-certificates:v1.15.0-alpha.0-62-g2c33dc1@sha256:69afca74404f025e342f9b834f345318bd8a333c25cb2a774c3fe80901fdf4ef"
    PKG_CNI                 = "ghcr.io/siderolabs/cni:v1.15.0-alpha.0-62-g2c33dc1@sha256:ccfa25837b5d47dd3fa05fd246ea7673b3ec14b965b4287436193dcd8967b2f0"
    PKG_CONTAINERD          = "ghcr.io/siderolabs/containerd:v1.15.0-alpha.0-62-g2c33dc1@sha256:1d15478b2b81a382d189ed10f6488351be29f4e55d6d443fc4dc5eab0a0dc7b2"
    PKG_CPIO                = "ghcr.io/siderolabs/cpio:v1.15.0-alpha.0-62-g2c33dc1@sha256:b87e48517a8b30ab1ef7d191c45abf0a44aa004a5eff5c71e3e8b5868f86ce47"
    PKG_CRYPTSETUP          = "ghcr.io/siderolabs/cryptsetup:v1.15.0-alpha.0-62-g2c33dc1@sha256:f0863cc13aa0f3aad4d0f69e0a028592c41972ff903ce1ce51e8005e5ae7da74"
    PKG_DOSFSTOOLS          = "ghcr.io/siderolabs/dosfstools:v1.15.0-alpha.0-62-g2c33dc1@sha256:382c859ae3df025225bda6bbf3bb0561def674d9f2fa995fd116250357d8380e"
    PKG_E2FSPROGS           = "ghcr.io/siderolabs/e2fsprogs:v1.15.0-alpha.0-62-g2c33dc1@sha256:7e05359f680c89649e9a276a552993e7f7b0259ee5d26940ba443cb915044cb7"
    PKG_FHS                 = "ghcr.io/siderolabs/fhs:v1.15.0-alpha.0-62-g2c33dc1@sha256:aa038d38eab4c3787a86d3ada41efd90405bcc32d45d73289b70f2dab235a19f"
    PKG_FLANNEL_CNI         = "ghcr.io/siderolabs/flannel-cni:v1.15.0-alpha.0-62-g2c33dc1@sha256:b93230bd960681bf8217446794d4c9c0c2c70ce09b43dd6db13a35e91100798a"
    PKG_GLIB                = "ghcr.io/siderolabs/glib:v1.15.0-alpha.0-62-g2c33dc1@sha256:d50b15c9aad465e3fce1e3ae46a4c1f3961abd10cf1ef616682ba9c3164fc7c8"
    PKG_GRUB                = "ghcr.io/siderolabs/grub:v1.15.0-alpha.0-62-g2c33dc1@sha256:39472eeb6c033ae258ad4ec11f066e7ab320b1fc3aa56cc612c02ea4e8476b85"
    PKG_IGZIP               = "ghcr.io/siderolabs/igzip:v1.15.0-alpha.0-62-g2c33dc1@sha256:1abdc05ce2a8cd641a1d9780eb813cb5cee4875c208be15799ed72f9b3fcdc48"
    PKG_IPTABLES            = "ghcr.io/siderolabs/iptables:v1.15.0-alpha.0-62-g2c33dc1@sha256:463d45acdc06029dacc57c3de6609944c044ddae690e78beb07746fb8922dbb7"
    PKG_IPXE                = "ghcr.io/siderolabs/ipxe:v1.15.0-alpha.0-62-g2c33dc1@sha256:f1e4a422c3fffacb83044436ca97fc5800cbd568848ed34fa8a0a96ccd17f41b"
    PKG_KMOD                = "ghcr.io/siderolabs/kmod:v1.15.0-alpha.0-62-g2c33dc1@sha256:94003c792f37b1cc0b78157f50e473266a4ab564fa14fef51bcd43cf9429765b"
    PKG_LIBAIO              = "ghcr.io/siderolabs/libaio:v1.15.0-alpha.0-62-g2c33dc1@sha256:55c2ccff11c56d48ef6c06880e1b032d55aaf2b22704d59e590294b5ca7129fe"
    PKG_LIBARCHIVE          = "ghcr.io/siderolabs/libarchive:v1.15.0-alpha.0-62-g2c33dc1@sha256:d1a2829fc20eab072b87c3a5bb2188475225aef3f84be4de9cc21dab9d5f6b14"
    PKG_LIBATTR             = "ghcr.io/siderolabs/libattr:v1.15.0-alpha.0-62-g2c33dc1@sha256:52a23a35a95e73bcfa76411ddc1b04ec71d34b74be11fe6b88f163f17a03bae0"
    PKG_LIBBURN             = "ghcr.io/siderolabs/libburn:v1.15.0-alpha.0-62-g2c33dc1@sha256:74512b082b84d7bc33e4a45b02a840229a41c8cc80923094fb4e5499d5ab04a6"
    PKG_LIBCAP              = "ghcr.io/siderolabs/libcap:v1.15.0-alpha.0-62-g2c33dc1@sha256:a80187bb419e7f17c259eb89796883d661093ca102888845833b20997e2951b4"
    PKG_LIBINIH             = "ghcr.io/siderolabs/libinih:v1.15.0-alpha.0-62-g2c33dc1@sha256:f73e40a482cd7833697456405a4bac13464fcbd83a49ec14f90b3a14a833301c"
    PKG_LIBISOBURN          = "ghcr.io/siderolabs/libisoburn:v1.15.0-alpha.0-62-g2c33dc1@sha256:168b4713681b48e9e9e6be0e7f42efd9995a1649904ba94fb18e1891bc7a2f65"
    PKG_LIBISOFS            = "ghcr.io/siderolabs/libisofs:v1.15.0-alpha.0-62-g2c33dc1@sha256:d2a67ef6b6df637b9579c605ab78f95abeaf3c58befd7b94d7b5cf3e688951e2"
    PKG_LIBJANSSON          = "ghcr.io/siderolabs/libjansson:v1.15.0-alpha.0-62-g2c33dc1@sha256:aeef64a3a549e59c799f115e21ca0aad7f4164e53e88d2a8cf6e67e62afeae0c"
    PKG_LIBJSON_C           = "ghcr.io/siderolabs/libjson-c:v1.15.0-alpha.0-62-g2c33dc1@sha256:dbabf78d995fb7a8a59ec9953ff693a4d38bd298ad791d7474eb94fe9e4d45c8"
    PKG_LIBLZMA             = "ghcr.io/siderolabs/liblzma:v1.15.0-alpha.0-62-g2c33dc1@sha256:4d23339dcb0e533fc31839ac98ddd6b915846923d4d842442f197ae3ddc24d98"
    PKG_LIBMNL              = "ghcr.io/siderolabs/libmnl:v1.15.0-alpha.0-62-g2c33dc1@sha256:87eb1954d777d6365ed3520b51d7827f675275027f5b294249d4f3ffe3d73e2d"
    PKG_LIBNFTNL            = "ghcr.io/siderolabs/libnftnl:v1.15.0-alpha.0-62-g2c33dc1@sha256:293479dd79e3adc6a8807ee3703119f97892bea4153059f1fd3dc96455d1dab5"
    PKG_LIBPOPT             = "ghcr.io/siderolabs/libpopt:v1.15.0-alpha.0-62-g2c33dc1@sha256:77207d245f76d3734334c190ced0f9f825036677585e2443a7ef7c80da51e23a"
    PKG_LIBSELINUX          = "ghcr.io/siderolabs/libselinux:v1.15.0-alpha.0-62-g2c33dc1@sha256:611407b679dc68f999e997543ed1a9e5a1124b725341f83ccb77da22a11e8b0e"
    PKG_LIBSEPOL            = "ghcr.io/siderolabs/libsepol:v1.15.0-alpha.0-62-g2c33dc1@sha256:e8793c6bbeb9c7dde25e2cfc975e8f22a110784aa33ed2561257f7f7e6a792d7"
    PKG_LIBUCONTEXT         = "ghcr.io/siderolabs/libucontext:v1.15.0-alpha.0-62-g2c33dc1@sha256:656ca60b1e5e2e2b7454a8ad4fea75799615aa7d7996d2bf767b613e8343cb01"
    PKG_LIBURCU             = "ghcr.io/siderolabs/liburcu:v1.15.0-alpha.0-62-g2c33dc1@sha256:c5dc027b46a74b17e3917961a582c23727f0e9492ec11beda98aa86b49011937"
    PKG_LINUX_FIRMWARE      = "ghcr.io/siderolabs/linux-firmware:v1.15.0-alpha.0-62-g2c33dc1@sha256:f5aace37c291a293eb5ff3f6511bdea503cbd60ecc38e919b0093a2aca4cfb15"
    PKG_LVM2                = "ghcr.io/siderolabs/lvm2:v1.15.0-alpha.0-62-g2c33dc1@sha256:d9e2dc4fb1ca46601748c649f6bfd59b245f04a90bdf67dbcbbbd249e1755cbc"
    PKG_MDADM               = "ghcr.io/siderolabs/mdadm-pkg:v1.15.0-alpha.0-62-g2c33dc1@sha256:060147a31e49023140cc643e24d09da7a7a808acd2d4bf7a25373d8d0769daf5"
    PKG_MTOOLS              = "ghcr.io/siderolabs/mtools:v1.15.0-alpha.0-62-g2c33dc1@sha256:f45317e753c05eb720390de05fbf24242fecd02def453dddb796bb194b2122f9"
    PKG_MUSL                = "ghcr.io/siderolabs/musl:v1.15.0-alpha.0-62-g2c33dc1@sha256:5586901193dd86080fa945203c3a1afb54906f1661238bbdbf5fd9169a16f8ec"
    PKG_NFTABLES            = "ghcr.io/siderolabs/nftables:v1.15.0-alpha.0-62-g2c33dc1@sha256:64aa75bfa4ae337e1ab2f4f1dea62a3cd48d7fa7c3a0bfe8a8fa7f67196cd08c"
    PKG_OPENSSL             = "ghcr.io/siderolabs/openssl:v1.15.0-alpha.0-62-g2c33dc1@sha256:5e22814efba8e9eeb807e03e81e1c52c8490fa6f13a5fe2104aac758931a6c67"
    PKG_OPEN_VMDK           = "ghcr.io/siderolabs/open-vmdk:v1.15.0-alpha.0-62-g2c33dc1@sha256:12009662fd636cc303e3211321c11554cae79dd5e9cd7358733731bd67e35c8c"
    PKG_PCRE2               = "ghcr.io/siderolabs/pcre2:v1.15.0-alpha.0-62-g2c33dc1@sha256:71b28ec0e8df5b8b565e25ad17d12f7172f322416f4b0ce52b13995ebc8bd6ca"
    PKG_PIGZ                = "ghcr.io/siderolabs/pigz:v1.15.0-alpha.0-62-g2c33dc1@sha256:73447910c8beea9963ec8f7230fc772036cbdadb6259b12d6128e6cee99e3c7c"
    PKG_QEMU_TOOLS          = "ghcr.io/siderolabs/qemu-tools:v1.15.0-alpha.0-62-g2c33dc1@sha256:93f8bda423930ebf4abac8d6f89e90a60feae2a45a17122b0edc049ec5fbf695"
    PKG_RUNC                = "ghcr.io/siderolabs/runc:v1.15.0-alpha.0-62-g2c33dc1@sha256:5e7f748756ba56a84e4e4c7bf23151c81a08e14cf1a309b54d0caf7c866fcdd5"
    PKG_SD_BOOT             = "ghcr.io/siderolabs/sd-boot:v1.15.0-alpha.0-62-g2c33dc1@sha256:67551ea2aed0914d94f2badb05adc0c48c4c8e70e8f925c74562aa0de56b045c"
    PKG_SQUASHFS_TOOLS      = "ghcr.io/siderolabs/squashfs-tools:v1.15.0-alpha.0-62-g2c33dc1@sha256:ffe9c49b6d50265fcb6e49b2f5f01eb6e00b50307340811369fe79ec941dd14b"
    PKG_SYSTEMD_UDEVD       = "ghcr.io/siderolabs/systemd-udevd:v1.15.0-alpha.0-62-g2c33dc1@sha256:7b52188f93d3dc08ce0a7bd869702a5f617267d9bc6a4bdacdf26dc231149423"
    PKG_TALOSCTL_CNI_BUNDLE = "ghcr.io/siderolabs/talosctl-cni-bundle:v1.15.0-alpha.0-62-g2c33dc1@sha256:624136ba3644b4c5b008fa3843d687e3d63e202f1d3dfc6dedf3da13c2c6d40c"
    PKG_TAR                 = "ghcr.io/siderolabs/tar:v1.15.0-alpha.0-62-g2c33dc1@sha256:d908e6e40992dbb4e4270471416ddc7ccb06fa71dd8172ba6e3c347c74a41092"
    PKG_UTIL_LINUX          = "ghcr.io/siderolabs/util-linux:v1.15.0-alpha.0-62-g2c33dc1@sha256:64b3a55ad943a7fde06218157670397356bde56f02986ee2cbe78fba793e672e"
    PKG_XFSPROGS            = "ghcr.io/siderolabs/xfsprogs:v1.15.0-alpha.0-62-g2c33dc1@sha256:3e3f59d792aa638de4eff2081d982a42f6ef09ebf78d0b17d64fe547291b1116"
    PKG_XZ                  = "ghcr.io/siderolabs/xz:v1.15.0-alpha.0-62-g2c33dc1@sha256:f5a4dc54d9aeebcddc8a6419ec5a55774ac6d109d0da58919aab1d361a7eb02a"
    PKG_ZLIB                = "ghcr.io/siderolabs/zlib:v1.15.0-alpha.0-62-g2c33dc1@sha256:3b0542d4d046908bcce040d9f361196a6a935582807af44ecc86cf00c461b6e7"
    PKG_ZSTD                = "ghcr.io/siderolabs/zstd:v1.15.0-alpha.0-62-g2c33dc1@sha256:01d35cc6d4f3d1d4f9ee712844e23cb06fa95d71025842db646e98c86190db92"
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
