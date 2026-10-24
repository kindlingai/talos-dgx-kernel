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
    PKGS                         = "v1.15.0-alpha.0-52-g305b1b6"
    PKGS_PREFIX                  = "ghcr.io/siderolabs"
    REGISTRY                     = "ghcr.io"
    SHA                          = TALOS_COMMIT
    TAG                          = TALOS_VERSION
    TESTPKGS                     = "github.com/siderolabs/talos/..."
    TOOLS                        = "v1.15.0-alpha.0-12-g32e115c@sha256:353cd1149ab17021ad3fa90cbfb2031926031d2e2931578ebb0739975806970a"
    TOOLS_PREFIX                 = "ghcr.io/siderolabs/tools"
    UNITTEST_PARALLELISM         = "8"
    USERNAME                     = "siderolabs"
    ZSTD_COMPRESSION_LEVEL       = "18"
    http_proxy                   = ""
    https_proxy                  = ""

    PKG_KERNEL              = "kernelcustom"
    PKG_RASPBERYPI_FIRMWARE = ""
    PKG_U_BOOT              = ""
    PKG_APPARMOR            = "ghcr.io/siderolabs/apparmor:v1.15.0-alpha.0-52-g305b1b6@sha256:95e29310661e009ec8aa8410ea112cdf8919c09ada5d62e2d6eb8c27ff65c9cc"
    PKG_BTRFSPROGS          = "ghcr.io/siderolabs/btrfsprogs:v1.15.0-alpha.0-52-g305b1b6@sha256:5d7cc2913422700e4a2122ee431b22823068637bf28c33a4acfe88e470cc2cae"
    PKG_CA_CERTIFICATES     = "ghcr.io/siderolabs/ca-certificates:v1.15.0-alpha.0-52-g305b1b6@sha256:86c00562b6df8c11250beeda0f4778bd70d8728f4b6f2b96e4c5052303881794"
    PKG_CNI                 = "ghcr.io/siderolabs/cni:v1.15.0-alpha.0-52-g305b1b6@sha256:3b21effc4f02d0a38eb0b6bfcae02b3b00afca31cd6cab51cc71215a35da34e1"
    PKG_CONTAINERD          = "ghcr.io/siderolabs/containerd:v1.15.0-alpha.0-52-g305b1b6@sha256:2ded06cbc13dc0c4db259534b96cb15c78267548ded38064ab9a4df2bca67400"
    PKG_CPIO                = "ghcr.io/siderolabs/cpio:v1.15.0-alpha.0-52-g305b1b6@sha256:b87e48517a8b30ab1ef7d191c45abf0a44aa004a5eff5c71e3e8b5868f86ce47"
    PKG_CRYPTSETUP          = "ghcr.io/siderolabs/cryptsetup:v1.15.0-alpha.0-52-g305b1b6@sha256:649d6a6b422361c85df594267fe3dd51906f78941cdf019e2b6cb5a28c79651d"
    PKG_DOSFSTOOLS          = "ghcr.io/siderolabs/dosfstools:v1.15.0-alpha.0-52-g305b1b6@sha256:798fb32ede4608e03edd4c7d69b19d5780704ef4785ad8902ef5f692461126ac"
    PKG_E2FSPROGS           = "ghcr.io/siderolabs/e2fsprogs:v1.15.0-alpha.0-52-g305b1b6@sha256:02f61bd3e0dfc3c503cbf0659ac7a25ba1fc1f8dc26638cee04e6bc0c174a226"
    PKG_FHS                 = "ghcr.io/siderolabs/fhs:v1.15.0-alpha.0-52-g305b1b6@sha256:aa038d38eab4c3787a86d3ada41efd90405bcc32d45d73289b70f2dab235a19f"
    PKG_FLANNEL_CNI         = "ghcr.io/siderolabs/flannel-cni:v1.15.0-alpha.0-52-g305b1b6@sha256:11e9f4592877463cf119b19b03fa8365944f4aad8b0477b72dbc02805991ac9b"
    PKG_GLIB                = "ghcr.io/siderolabs/glib:v1.15.0-alpha.0-52-g305b1b6@sha256:d50b15c9aad465e3fce1e3ae46a4c1f3961abd10cf1ef616682ba9c3164fc7c8"
    PKG_GRUB                = "ghcr.io/siderolabs/grub:v1.15.0-alpha.0-52-g305b1b6@sha256:39472eeb6c033ae258ad4ec11f066e7ab320b1fc3aa56cc612c02ea4e8476b85"
    PKG_IGZIP               = "ghcr.io/siderolabs/igzip:v1.15.0-alpha.0-52-g305b1b6@sha256:c635c76ba46fd45f85bc8a59e53db26d497e0993aae55990d8cf0f11fa5d5e41"
    PKG_IPTABLES            = "ghcr.io/siderolabs/iptables:v1.15.0-alpha.0-52-g305b1b6@sha256:ab8dd7178b9b577c88671878db5845634b1264a3a889092a1af3f7f8da758ba8"
    PKG_IPXE                = "ghcr.io/siderolabs/ipxe:v1.15.0-alpha.0-52-g305b1b6@sha256:f1e4a422c3fffacb83044436ca97fc5800cbd568848ed34fa8a0a96ccd17f41b"
    PKG_KMOD                = "ghcr.io/siderolabs/kmod:v1.15.0-alpha.0-52-g305b1b6@sha256:6d81ac69de922e07a7a6dc3a3255ace038be6148af93cd667146c85bb157f0aa"
    PKG_LIBAIO              = "ghcr.io/siderolabs/libaio:v1.15.0-alpha.0-52-g305b1b6@sha256:28ec0ebf2204b0b57de533a7fc63d54e8a7cd7a277cde0dd51a0726e3b846f01"
    PKG_LIBARCHIVE          = "ghcr.io/siderolabs/libarchive:v1.15.0-alpha.0-52-g305b1b6@sha256:2e4a74a0dad3a7aa4bd3b6a78ee7a15f7808585928160f1e0389feaa36708c37"
    PKG_LIBATTR             = "ghcr.io/siderolabs/libattr:v1.15.0-alpha.0-52-g305b1b6@sha256:90ad4ca4810241dca32771cd8c2df565c5e7a9da9831b7c917f8f559d938e1f7"
    PKG_LIBBURN             = "ghcr.io/siderolabs/libburn:v1.15.0-alpha.0-52-g305b1b6@sha256:74512b082b84d7bc33e4a45b02a840229a41c8cc80923094fb4e5499d5ab04a6"
    PKG_LIBCAP              = "ghcr.io/siderolabs/libcap:v1.15.0-alpha.0-52-g305b1b6@sha256:b76f6ef1bcc862f0da7b69d67aeaecc6cdb37da2403e5b0d82d783f4164ef11a"
    PKG_LIBINIH             = "ghcr.io/siderolabs/libinih:v1.15.0-alpha.0-52-g305b1b6@sha256:a03e6e11896139cfbd0c352a8560b14672eabbdff97491d8d9f27470e388c05c"
    PKG_LIBISOBURN          = "ghcr.io/siderolabs/libisoburn:v1.15.0-alpha.0-52-g305b1b6@sha256:168b4713681b48e9e9e6be0e7f42efd9995a1649904ba94fb18e1891bc7a2f65"
    PKG_LIBISOFS            = "ghcr.io/siderolabs/libisofs:v1.15.0-alpha.0-52-g305b1b6@sha256:d2a67ef6b6df637b9579c605ab78f95abeaf3c58befd7b94d7b5cf3e688951e2"
    PKG_LIBJANSSON          = "ghcr.io/siderolabs/libjansson:v1.15.0-alpha.0-52-g305b1b6@sha256:31d1d3dc480a91a9592780cc8697fc3a9b75559922a85939516debbddfc3a738"
    PKG_LIBJSON_C           = "ghcr.io/siderolabs/libjson-c:v1.15.0-alpha.0-52-g305b1b6@sha256:16a6342e1892d2649d9a5a17f6b39651ea8b74edc09f2c629e026451b27a7862"
    PKG_LIBLZMA             = "ghcr.io/siderolabs/liblzma:v1.15.0-alpha.0-52-g305b1b6@sha256:4d23339dcb0e533fc31839ac98ddd6b915846923d4d842442f197ae3ddc24d98"
    PKG_LIBMNL              = "ghcr.io/siderolabs/libmnl:v1.15.0-alpha.0-52-g305b1b6@sha256:5b1d7d90a7ee6be1b932e4d20e5bf62729b5b243028f94ce3383f869c9f277e0"
    PKG_LIBNFTNL            = "ghcr.io/siderolabs/libnftnl:v1.15.0-alpha.0-52-g305b1b6@sha256:a7f70e8840495c9559a7cde45254fcb5d8745e328f2823f7525dbed13a48e645"
    PKG_LIBPOPT             = "ghcr.io/siderolabs/libpopt:v1.15.0-alpha.0-52-g305b1b6@sha256:25978b4dd3e102f6481127b5283cf809768fdf836d0879cbed21adc2234a4337"
    PKG_LIBSELINUX          = "ghcr.io/siderolabs/libselinux:v1.15.0-alpha.0-52-g305b1b6@sha256:7278f71783e0591920d5807f2e2f5ff2f6b0874886e4eed2172991a70a56df0f"
    PKG_LIBSEPOL            = "ghcr.io/siderolabs/libsepol:v1.15.0-alpha.0-52-g305b1b6@sha256:b402fd218f3739ce72c10d9ed61f0150c9e3b6c36a81f3c5ea08c716ab8f783c"
    PKG_LIBUCONTEXT         = "ghcr.io/siderolabs/libucontext:v1.15.0-alpha.0-52-g305b1b6@sha256:59b70f9ff0e7253cf4b5666ec43d371b4b222321769455b15e5b52206975b680"
    PKG_LIBURCU             = "ghcr.io/siderolabs/liburcu:v1.15.0-alpha.0-52-g305b1b6@sha256:d5deb605f402e6460b982c99f6fbcbd8e4345c45a284fdf7c96f3a8f3a3dad2b"
    PKG_LINUX_FIRMWARE      = "ghcr.io/siderolabs/linux-firmware:v1.15.0-alpha.0-52-g305b1b6@sha256:f5aace37c291a293eb5ff3f6511bdea503cbd60ecc38e919b0093a2aca4cfb15"
    PKG_LVM2                = "ghcr.io/siderolabs/lvm2:v1.15.0-alpha.0-52-g305b1b6@sha256:a2a641927d8de4d3e3689fd5ab8b310ebdb7b10703390c391072a78e376c2566"
    PKG_MDADM               = "ghcr.io/siderolabs/mdadm-pkg:v1.15.0-alpha.0-52-g305b1b6@sha256:8c521c298cee4ee4ddc48fadf531859be9d6f2e374671e5ec2afeb6e9e13f934"
    PKG_MTOOLS              = "ghcr.io/siderolabs/mtools:v1.15.0-alpha.0-52-g305b1b6@sha256:f45317e753c05eb720390de05fbf24242fecd02def453dddb796bb194b2122f9"
    PKG_MUSL                = "ghcr.io/siderolabs/musl:v1.15.0-alpha.0-52-g305b1b6@sha256:04ffe74e898a635ec9513ffabe59ba345aef7f5ba4abdaeeb667c378160c769f"
    PKG_NFTABLES            = "ghcr.io/siderolabs/nftables:v1.15.0-alpha.0-52-g305b1b6@sha256:db342d6283ce47dde89825acb7685c7ff1595af6304653fe86467a6cd746a1ab"
    PKG_OPENSSL             = "ghcr.io/siderolabs/openssl:v1.15.0-alpha.0-52-g305b1b6@sha256:c770d146c5ba9108f196d3d5e54333f134f11c2f9a27b9786cae8d2315c94e20"
    PKG_OPEN_VMDK           = "ghcr.io/siderolabs/open-vmdk:v1.15.0-alpha.0-52-g305b1b6@sha256:12009662fd636cc303e3211321c11554cae79dd5e9cd7358733731bd67e35c8c"
    PKG_PCRE2               = "ghcr.io/siderolabs/pcre2:v1.15.0-alpha.0-52-g305b1b6@sha256:a5cbbb0be37972380f1b352a6528fc9b223468197a54bfdd39b9054d041e3da9"
    PKG_PIGZ                = "ghcr.io/siderolabs/pigz:v1.15.0-alpha.0-52-g305b1b6@sha256:c5a9fef97ce58a4f751b07e23cfdce3ddbf4336bc1e15c4eb7c35eb49df01bfb"
    PKG_QEMU_TOOLS          = "ghcr.io/siderolabs/qemu-tools:v1.15.0-alpha.0-52-g305b1b6@sha256:93f8bda423930ebf4abac8d6f89e90a60feae2a45a17122b0edc049ec5fbf695"
    PKG_RUNC                = "ghcr.io/siderolabs/runc:v1.15.0-alpha.0-52-g305b1b6@sha256:e2d41d8ea588143d2e24332a802cdd02b0620749a67b01b6428d60af240a83ed"
    PKG_SD_BOOT             = "ghcr.io/siderolabs/sd-boot:v1.15.0-alpha.0-52-g305b1b6@sha256:67551ea2aed0914d94f2badb05adc0c48c4c8e70e8f925c74562aa0de56b045c"
    PKG_SQUASHFS_TOOLS      = "ghcr.io/siderolabs/squashfs-tools:v1.15.0-alpha.0-52-g305b1b6@sha256:ffe9c49b6d50265fcb6e49b2f5f01eb6e00b50307340811369fe79ec941dd14b"
    PKG_SYSTEMD_UDEVD       = "ghcr.io/siderolabs/systemd-udevd:v1.15.0-alpha.0-52-g305b1b6@sha256:2242e40919dc9765febe1bd89a4023e56af6471b8989aefd5d7156feeac2a53b"
    PKG_TALOSCTL_CNI_BUNDLE = "ghcr.io/siderolabs/talosctl-cni-bundle:v1.15.0-alpha.0-52-g305b1b6@sha256:80d022b75d9251ec96b87149dea049463cd7869042d607909cef4db77499f408"
    PKG_TAR                 = "ghcr.io/siderolabs/tar:v1.15.0-alpha.0-52-g305b1b6@sha256:4c66b10ede6ca0fde4829d465cd268ce734ea8616bb51381be357786f2672133"
    PKG_UTIL_LINUX          = "ghcr.io/siderolabs/util-linux:v1.15.0-alpha.0-52-g305b1b6@sha256:d5e10d7954ca1558431ecf2c3e3ab71cdcab580de32ad472587d7a9e8faa4efb"
    PKG_XFSPROGS            = "ghcr.io/siderolabs/xfsprogs:v1.15.0-alpha.0-52-g305b1b6@sha256:776c7e70ebab2e497cd032a49ac5e065fd7c6154f971974f0763e6b3c3bfbfbb"
    PKG_XZ                  = "ghcr.io/siderolabs/xz:v1.15.0-alpha.0-52-g305b1b6@sha256:0819f2345657348ba24cbd8cfa9faafced401f610c3c943ab9cf2a2af5581402"
    PKG_ZLIB                = "ghcr.io/siderolabs/zlib:v1.15.0-alpha.0-52-g305b1b6@sha256:f638a44ef1690421f36f1712a6dbaec783bcc794160390c2e7c9f6699221a55b"
    PKG_ZSTD                = "ghcr.io/siderolabs/zstd:v1.15.0-alpha.0-52-g305b1b6@sha256:8f582940e3c75ae5f0749e0a26c5e44440714a59b0f069b82b7524d81a921add"
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
