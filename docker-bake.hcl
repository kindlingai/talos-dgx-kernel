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
variable "KERNEL_RELEASE" {}
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
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/kernel"]
}

target "nvidia-extension" {
  inherits = ["_kernel"]
  target   = "nvidia-extension"
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/nvidia-extension"]
}

target "dispram-extension" {
  inherits = ["_kernel"]
  target   = "dispram-extension"
  output   = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/dispram-extension"]
}

group "kernel" {
  targets = ["kernel", "nvidia-extension", "dispram-extension"]
}

# Talos's own Dockerfile, built with the arguments its Makefile passes at
# TALOS_COMMIT, package images pinned by digest, and PKG_KERNEL replaced by the
# kernel OCI layout.
target "_talos" {
  inherits   = ["_reproducible"]
  context    = TALOS_SRC
  dockerfile = "Dockerfile"
  contexts = {
    kernelcustom = "oci-layout://${OUT}/oci/kernel"
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
    PKGS                         = "v1.14.0-25-gf694e1b"
    PKGS_PREFIX                  = "ghcr.io/siderolabs"
    REGISTRY                     = "ghcr.io"
    SHA                          = TALOS_COMMIT
    TAG                          = TALOS_VERSION
    TESTPKGS                     = "github.com/siderolabs/talos/..."
    TOOLS                        = "v1.14.0-7-ga404efb@sha256:ad7d2319c0c88f81da2a6ed425515ab2898d3054e0dfe63c056eb06133e2722b"
    TOOLS_PREFIX                 = "ghcr.io/siderolabs/tools"
    UNITTEST_PARALLELISM         = "8"
    USERNAME                     = "siderolabs"
    ZSTD_COMPRESSION_LEVEL       = "18"
    http_proxy                   = ""
    https_proxy                  = ""

    PKG_KERNEL              = "kernelcustom"
    PKG_RASPBERYPI_FIRMWARE = ""
    PKG_U_BOOT              = ""
    PKG_APPARMOR            = "ghcr.io/siderolabs/apparmor:v1.14.0-25-gf694e1b@sha256:8746cc26a01e99afc12d1d995246695ba3ae910a4aec9b256a93169f09ee62a3"
    PKG_BTRFSPROGS          = "ghcr.io/siderolabs/btrfsprogs:v1.14.0-25-gf694e1b@sha256:8a9ab88d4c5af0c82435e0732029cc0c398a668723a6a0b0eee27aebd7fcd769"
    PKG_CA_CERTIFICATES     = "ghcr.io/siderolabs/ca-certificates:v1.14.0-25-gf694e1b@sha256:86c00562b6df8c11250beeda0f4778bd70d8728f4b6f2b96e4c5052303881794"
    PKG_CNI                 = "ghcr.io/siderolabs/cni:v1.14.0-25-gf694e1b@sha256:506e2c06dcd1297512e739bb9794d4a5bdc729c181a00980fab3bf92adaf072a"
    PKG_CONTAINERD          = "ghcr.io/siderolabs/containerd:v1.14.0-25-gf694e1b@sha256:6737d2f431ac5c181aef7aac44cbbb87ac9370b6d34e5298ed0a47f9be8bc854"
    PKG_CPIO                = "ghcr.io/siderolabs/cpio:v1.14.0-25-gf694e1b@sha256:b87e48517a8b30ab1ef7d191c45abf0a44aa004a5eff5c71e3e8b5868f86ce47"
    PKG_CRYPTSETUP          = "ghcr.io/siderolabs/cryptsetup:v1.14.0-25-gf694e1b@sha256:ab092143a2358569630faf069525f4e17f5b6cdb09b9d5c025739796dcfdc6f2"
    PKG_DOSFSTOOLS          = "ghcr.io/siderolabs/dosfstools:v1.14.0-25-gf694e1b@sha256:3f6a793b793716ed84d8a03023585a2ef03f8a128ffcf5b9f0a72ace3371b05a"
    PKG_E2FSPROGS           = "ghcr.io/siderolabs/e2fsprogs:v1.14.0-25-gf694e1b@sha256:e619a7e6cf31ebe242cdd830a5b8f77bfa8a8d802ec26c5c984d7d1b6c5e8c24"
    PKG_FHS                 = "ghcr.io/siderolabs/fhs:v1.14.0-25-gf694e1b@sha256:aa038d38eab4c3787a86d3ada41efd90405bcc32d45d73289b70f2dab235a19f"
    PKG_FLANNEL_CNI         = "ghcr.io/siderolabs/flannel-cni:v1.14.0-25-gf694e1b@sha256:5b223315c9d3f0ac38706b7d8bde37a2e94116a3c1dccf6ca03c58e06c422942"
    PKG_GLIB                = "ghcr.io/siderolabs/glib:v1.14.0-25-gf694e1b@sha256:b6af63302467b7dc8179dd2e59709e1643341162cd87c0fa453854a50d036dfd"
    PKG_GRUB                = "ghcr.io/siderolabs/grub:v1.14.0-25-gf694e1b@sha256:39472eeb6c033ae258ad4ec11f066e7ab320b1fc3aa56cc612c02ea4e8476b85"
    PKG_IGZIP               = "ghcr.io/siderolabs/igzip:v1.14.0-25-gf694e1b@sha256:2ba82ccc813df2a0362ed1f6cbe7aab02f1c0c47fd67803b4a8c484fd854dcd4"
    PKG_IPTABLES            = "ghcr.io/siderolabs/iptables:v1.14.0-25-gf694e1b@sha256:3d43a5496da234aad7ecc73d3569f1f4934fad3b8857a34880d61eafda81e4ad"
    PKG_IPXE                = "ghcr.io/siderolabs/ipxe:v1.14.0-25-gf694e1b@sha256:af7909795d0c8bd173cf18dea46cdb1d650bc06c358879e03bb7ff462c5c1fb2"
    PKG_KMOD                = "ghcr.io/siderolabs/kmod:v1.14.0-25-gf694e1b@sha256:9fe2005b1b6166401e19d074f57f02c8444219d7dd0f14fcb5f9b56fbcd2403b"
    PKG_LIBAIO              = "ghcr.io/siderolabs/libaio:v1.14.0-25-gf694e1b@sha256:6c597b22981a4e23713c58bd9d90f87ebb066c070a7b76c2755b62c060cd6fbe"
    PKG_LIBARCHIVE          = "ghcr.io/siderolabs/libarchive:v1.14.0-25-gf694e1b@sha256:6b10acf620454d4e84412f69e7866683ae57c6a231bf3cdc8faf73f588dbe77d"
    PKG_LIBATTR             = "ghcr.io/siderolabs/libattr:v1.14.0-25-gf694e1b@sha256:d442f504dee78a72b369fcb42e3d0ee21bc7a4f5192e7795776730bc82b9e3ea"
    PKG_LIBBURN             = "ghcr.io/siderolabs/libburn:v1.14.0-25-gf694e1b@sha256:74512b082b84d7bc33e4a45b02a840229a41c8cc80923094fb4e5499d5ab04a6"
    PKG_LIBCAP              = "ghcr.io/siderolabs/libcap:v1.14.0-25-gf694e1b@sha256:9baa82d1d96c2527a99ba4cef36f674e9665e55c22a622a4a487d6dff8d481fa"
    PKG_LIBINIH             = "ghcr.io/siderolabs/libinih:v1.14.0-25-gf694e1b@sha256:bdb444cd4de2c8cf40f22a49a006893a93259a6db4035809399481622f4071c9"
    PKG_LIBISOBURN          = "ghcr.io/siderolabs/libisoburn:v1.14.0-25-gf694e1b@sha256:168b4713681b48e9e9e6be0e7f42efd9995a1649904ba94fb18e1891bc7a2f65"
    PKG_LIBISOFS            = "ghcr.io/siderolabs/libisofs:v1.14.0-25-gf694e1b@sha256:d2a67ef6b6df637b9579c605ab78f95abeaf3c58befd7b94d7b5cf3e688951e2"
    PKG_LIBJANSSON          = "ghcr.io/siderolabs/libjansson:v1.14.0-25-gf694e1b@sha256:dff8f94e717c81f3141b3ecf4064e9f4d254db928f6c9de17938d69d31aeb8d4"
    PKG_LIBJSON_C           = "ghcr.io/siderolabs/libjson-c:v1.14.0-25-gf694e1b@sha256:2e89c555a2d97a027b6f2ff22688e70efc108d91b1dc2160473bf58a411b1a97"
    PKG_LIBLZMA             = "ghcr.io/siderolabs/liblzma:v1.14.0-25-gf694e1b@sha256:49a26433b0d7214750e24063da268553fcb25ae22eec372e1226d994552edb67"
    PKG_LIBMNL              = "ghcr.io/siderolabs/libmnl:v1.14.0-25-gf694e1b@sha256:2114c745d6461ee4193d660d1270448833e21c6713f7bc8211bc4addb37bf49f"
    PKG_LIBNFTNL            = "ghcr.io/siderolabs/libnftnl:v1.14.0-25-gf694e1b@sha256:9fb86256221cd70edde7fbaf75cf7e460b7cf25fda8db1dd2eec1b24f0f17004"
    PKG_LIBPOPT             = "ghcr.io/siderolabs/libpopt:v1.14.0-25-gf694e1b@sha256:a68fe073d753fe71447f88c370f9950a4ce9a961b25ede655f70ed48594d3fb8"
    PKG_LIBSELINUX          = "ghcr.io/siderolabs/libselinux:v1.14.0-25-gf694e1b@sha256:f6b7d57c8fa863257c88c47229798c858dee9b92f41ec3e688f009b952a871c8"
    PKG_LIBSEPOL            = "ghcr.io/siderolabs/libsepol:v1.14.0-25-gf694e1b@sha256:ffeaaaa3c18965a45c6fa558691121119556c7f66f92541ec25ffebdb2ee562b"
    PKG_LIBUCONTEXT         = "ghcr.io/siderolabs/libucontext:v1.14.0-25-gf694e1b@sha256:07cc1c66e78aa9318f238feedab106c7bce2c2c64b59d8e86e29fd5ee49bd019"
    PKG_LIBURCU             = "ghcr.io/siderolabs/liburcu:v1.14.0-25-gf694e1b@sha256:e5171e695e9f0396e86025153558d46c315da460f1d5d423887e3d71dea5e7f7"
    PKG_LINUX_FIRMWARE      = "ghcr.io/siderolabs/linux-firmware:v1.14.0-25-gf694e1b@sha256:93a8a8115544f989bf8d5c3299624cba9313a07f7c3a5c18b63083940a439616"
    PKG_LVM2                = "ghcr.io/siderolabs/lvm2:v1.14.0-25-gf694e1b@sha256:64e69abad052c2355f37ce1dbcb85a8fd90a85357bb3718137de766638f40071"
    PKG_MDADM               = "ghcr.io/siderolabs/mdadm-pkg:v1.14.0-25-gf694e1b@sha256:9ea2d36faa8ad5cb273bf88695b5e12f13d5590b955597a189b164043ce5e696"
    PKG_MTOOLS              = "ghcr.io/siderolabs/mtools:v1.14.0-25-gf694e1b@sha256:f45317e753c05eb720390de05fbf24242fecd02def453dddb796bb194b2122f9"
    PKG_MUSL                = "ghcr.io/siderolabs/musl:v1.14.0-25-gf694e1b@sha256:8140be4d87243dda0398468e752d9ba6343dd9f4e164e891c66731cf85e67255"
    PKG_NFTABLES            = "ghcr.io/siderolabs/nftables:v1.14.0-25-gf694e1b@sha256:31598728db98e1a5c9492b109b8af401b48cb3786cc9ebc2c96a579b025db21b"
    PKG_OPENSSL             = "ghcr.io/siderolabs/openssl:v1.14.0-25-gf694e1b@sha256:e69ee3532bb8162b496c4c39fcb6eb024ea7401105ae46a4e6a01a2550a19c24"
    PKG_OPEN_VMDK           = "ghcr.io/siderolabs/open-vmdk:v1.14.0-25-gf694e1b@sha256:12009662fd636cc303e3211321c11554cae79dd5e9cd7358733731bd67e35c8c"
    PKG_PCRE2               = "ghcr.io/siderolabs/pcre2:v1.14.0-25-gf694e1b@sha256:540455b2ebb4d078494c18ac141d073c67fc669ea523accdd132a9438e18ac45"
    PKG_PIGZ                = "ghcr.io/siderolabs/pigz:v1.14.0-25-gf694e1b@sha256:15b17a7e0c155f5040cc24c013855f883ea26f6003ca6194be91f4b7a2043890"
    PKG_QEMU_TOOLS          = "ghcr.io/siderolabs/qemu-tools:v1.14.0-25-gf694e1b@sha256:a54a15feff6e817da6134189bca3f42e288d1be0819a0972a2d422cdf9e9f980"
    PKG_RUNC                = "ghcr.io/siderolabs/runc:v1.14.0-25-gf694e1b@sha256:ffc9de33d647c5e9e03b05d9fed05fc1e590ec851223be97ed9c9d07de8a2172"
    PKG_SD_BOOT             = "ghcr.io/siderolabs/sd-boot:v1.14.0-25-gf694e1b@sha256:b18008c453500d893adc3711ed891b23c56fe21080251d49744095dcc73a9e48"
    PKG_SQUASHFS_TOOLS      = "ghcr.io/siderolabs/squashfs-tools:v1.14.0-25-gf694e1b@sha256:ffe9c49b6d50265fcb6e49b2f5f01eb6e00b50307340811369fe79ec941dd14b"
    PKG_SYSTEMD_UDEVD       = "ghcr.io/siderolabs/systemd-udevd:v1.14.0-25-gf694e1b@sha256:337ab26b6c7657f68b5eecfad59503572fe0cd2e3c04d1caef1abaa6b3a8f10b"
    PKG_TALOSCTL_CNI_BUNDLE = "ghcr.io/siderolabs/talosctl-cni-bundle:v1.14.0-25-gf694e1b@sha256:09aee1bb19b042d00d4bca45ef05f2e57f22c569d1be676cb0ab339bcea62190"
    PKG_TAR                 = "ghcr.io/siderolabs/tar:v1.14.0-25-gf694e1b@sha256:44e51d10ff7141115957a279108d68426bae78daff1212644f3606a07f064e23"
    PKG_UTIL_LINUX          = "ghcr.io/siderolabs/util-linux:v1.14.0-25-gf694e1b@sha256:ac9d44ca64b5b95a0ac910240b4cf0d2ff665f6e9bdd77751ce37abdea957d97"
    PKG_XFSPROGS            = "ghcr.io/siderolabs/xfsprogs:v1.14.0-25-gf694e1b@sha256:9c5cc6d6d27a57c5c480366ce81d54177abf2722ca0958e11f33ecd7ddc59d9c"
    PKG_XZ                  = "ghcr.io/siderolabs/xz:v1.14.0-25-gf694e1b@sha256:f721f7c3bdd25b304f63ff9175d3bf735495b7b44836f10d07f3ae5edd506beb"
    PKG_ZLIB                = "ghcr.io/siderolabs/zlib:v1.14.0-25-gf694e1b@sha256:9d3d2273f85280f7f772c7c6b3a95fecfc34f626bf95b1cbf947b424e1194a4b"
    PKG_ZSTD                = "ghcr.io/siderolabs/zstd:v1.14.0-25-gf694e1b@sha256:11fa9df59731f3c78fa776c931fd44620b4951f043389418717edb841f7d7cd5"
  }
}

target "installer-base" {
  inherits  = ["_talos"]
  target    = "installer-base"
  platforms = ["linux/arm64"]
  output    = ["type=oci,tar=false,rewrite-timestamp=true,dest=${OUT}/oci/installer-base"]
}

# The imager runs on the build host and carries the arm64 kernel and initramfs.
target "imager" {
  inherits = ["_talos"]
  target   = "imager"
  args = {
    INSTALLER_ARCH = "arm64"
  }
  tags   = ["talos-dgx-kernel/imager:${TALOS_VERSION}"]
  output = ["type=docker,rewrite-timestamp=true"]
}

group "talos" {
  targets = ["installer-base", "imager"]
}
