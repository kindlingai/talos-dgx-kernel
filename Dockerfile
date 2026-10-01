# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e

# Linux kernel and NVIDIA kernel modules for Talos on NVIDIA DGX Spark (arm64).
#
# Targets:
#   kernel            Talos PKG_KERNEL image
#   nvidia-extension  Talos system extension with the NVIDIA and GDS modules
#
# docker-bake.hcl supplies the build arguments and the module signing key.

ARG LLVM_IMAGE=ghcr.io/siderolabs/llvm@sha256:251882062d6ce367b3125bf50e64db69e42e09ddc03003d4a37b75c482f46496
ARG TOOLS_IMAGE=ghcr.io/siderolabs/tools@sha256:ad7d2319c0c88f81da2a6ed425515ab2898d3054e0dfe63c056eb06133e2722b
ARG VALIDATOR_IMAGE=ghcr.io/siderolabs/extensions-validator@sha256:3737c0e2f22e66382bddcdaab61e305eae453913ad3ba9b6096e96647daae800

FROM scratch AS downloads
ARG NVIDIA_VERSION
ARG GDS_VERSION
ADD --checksum=sha256:a5623ec5af79da8807e1467e43a1888461c7a445fb1e17533fe45f0fdf4394e3 \
    https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-nvidia-6.17/linux-nvidia-6.17_6.17.0.orig.tar.gz /linux.tar.gz
# Launchpad serves the .diff.gz with Content-Encoding: gzip, so BuildKit receives
# and checks the uncompressed diff.
ADD --checksum=sha256:59db6c06597b7fe7a009da32e58f179a939109ee9b61dd041e895c3f6a4d1205 \
    https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/linux-nvidia-6.17/6.17.0-1022.22/linux-nvidia-6.17_6.17.0-1022.22.diff.gz /linux-nvidia.diff
ADD --checksum=sha256:8e55dfbe85b1aa9fbd2e323ed203470ebf6001f614d1f8cb4fa0671ea979a557 \
    https://developer.download.nvidia.com/compute/nvidia-driver/redist/nvidia_driver/linux-sbsa/nvidia_driver-linux-sbsa-${NVIDIA_VERSION}-archive.tar.xz /nvidia.tar.xz
ADD --checksum=sha256:6936aeacfb519a1d6fe66e16281799c20ffe177c2022f831d29f90895f11e339 \
    https://codeload.github.com/NVIDIA/gds-nvidia-fs/tar.gz/refs/tags/v${GDS_VERSION} /gds.tar.gz

FROM --platform=$BUILDPLATFORM ${LLVM_IMAGE} AS llvm
FROM --platform=$BUILDPLATFORM ${VALIDATOR_IMAGE} AS validator

# Sidero Labs tools and LLVM run natively on the build host and target arm64.
FROM --platform=$BUILDPLATFORM ${TOOLS_IMAGE} AS toolchain
COPY --from=llvm / /
ENV PATH=/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C \
    TZ=UTC \
    ARCH=arm64 \
    LLVM=1 \
    CROSS_COMPILE=aarch64-linux-musl- \
    KBUILD_BUILD_USER=talos \
    KBUILD_BUILD_HOST=dgx-builder \
    KBUILD_BUILD_VERSION=1

FROM toolchain AS linux-src
WORKDIR /src/linux
RUN --mount=type=bind,source=scripts,target=/scripts \
    --mount=type=bind,source=kernel/patches,target=/patches \
    --mount=type=bind,from=downloads,target=/downloads \
    /scripts/prepare-linux.sh /downloads /patches

FROM linux-src AS kernel-build
ARG KERNEL_RELEASE
ARG SOURCE_DATE_EPOCH
ARG JOBS
RUN --mount=type=bind,source=scripts,target=/scripts \
    --mount=type=bind,source=kernel/config,target=/config \
    --mount=type=secret,id=module_signing_key,required=true \
    /scripts/build-kernel.sh /config /rootfs

FROM scratch AS kernel
COPY --link --from=kernel-build /rootfs/ /
COPY --link kernel/kernel.spdx.json /usr/share/spdx/kernel.spdx.json

FROM kernel-build AS nvidia-build
ARG KERNEL_RELEASE
ARG JOBS
WORKDIR /src
RUN --mount=type=bind,source=scripts,target=/scripts \
    --mount=type=bind,from=downloads,target=/downloads \
    --mount=type=secret,id=module_signing_key,required=true \
    /scripts/build-nvidia.sh /downloads /rootfs /extension/rootfs
COPY extension/manifest.yaml /extension/manifest.yaml
COPY extension/nvidia.conf /extension/rootfs/usr/local/lib/modprobe.d/nvidia.conf
COPY extension/kmod-nvidia-lts.spdx.json /extension/rootfs/usr/local/share/spdx/kmod-nvidia-lts.spdx.json
RUN --mount=type=bind,source=scripts,target=/scripts \
    --mount=type=bind,from=validator,source=/extensions-validator,target=/usr/local/bin/extensions-validator \
    /scripts/check-extension.sh /rootfs /extension

FROM scratch AS nvidia-extension
COPY --link --from=nvidia-build /extension/ /
