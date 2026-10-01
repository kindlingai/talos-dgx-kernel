# Talos DGX kernel

Minimal source package for building the custom ARM64 Talos kernel and installer
used on NVIDIA DGX Spark. This is not an Ubuntu/DGX OS kernel package.

The starting point is the boot-tested combination:

- Talos `v1.14.1`
- Linux `6.17.13-talos-dgx1022-buildonly`
- NVIDIA driver `580.178.04`
- Realtek RTL8127 Ethernet and Mellanox ConnectX support

The build recipe is being extracted from that working build. Build and install
commands will be documented once they have been exercised from this repository.

Only build inputs, required patches, build scripts, and installation instructions
belong here. Downloaded sources, build outputs, signing keys, credentials, machine
configurations, benchmark data, and recovery logs do not.

Each builder must generate its own module-signing key; the key used for the
original installation is not distributed. Installers must include the matching
kernel, signed modules, and Talos kernel-version constant together. Hardware
network selection must not assume the stock `r8169` driver on RTL8127 machines.
