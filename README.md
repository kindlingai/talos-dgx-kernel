# Talos DGX kernel

Build the custom ARM64 Talos kernel and installer used on NVIDIA DGX Spark:
**Talos v1.14.1, Linux 6.17.13-talos-dgx1022-buildonly, NVIDIA 580.178.04**.
This is a Talos installer, not an Ubuntu/DGX OS package.

The source/configuration comes from the boot-tested build. These standalone
scripts have syntax/unit checks, but **have not been used for another full build**.
The repository is a source delivery; it contains no prebuilt installer.

## Requirements

- Native **Linux AMD64** build host with local Docker Engine and Docker buildx.
  The compiler cross-builds ARM64; Docker Desktop on ARM64 is not supported.
- Python 3.9+, Git, internet access to the source/image registries.
- At least **4 CPUs and 30 GiB RAM available to the build container**. This is
  the allocation used successfully before extraction into this repository.
- A private work directory on a case-sensitive Linux filesystem, with space for
  the kernel source, objects, ThinLTO cache, downloaded images, and installer.
- For installation: a compatible existing Talos system, matching `talosctl`,
  that node's own credentials, registry access, and console/recovery access.

## Build

Run these commands on the build host, from a fresh clone:

```sh
git clone git@github.com:coffee-the-dev/talos-dgx-kernel.git
cd talos-dgx-kernel
umask 077
mkdir -p .work

docker build --platform linux/amd64 \
  --file kernel/Toolchain.Dockerfile --tag talos-dgx-kernel/toolchain:local kernel

# Download checksum-locked sources, apply the vendor delta and 20 ordered patches.
docker run --rm --platform linux/amd64 \
  --mount "type=bind,src=$PWD,dst=/input,readonly" \
  --mount "type=bind,src=$PWD/.work,dst=/work" \
  talos-dgx-kernel/toolchain:local python3 /input/prepare.py --work /work

# Compile/sign the kernel and matching NVIDIA/GDS modules, without network access.
docker run --rm --platform linux/amd64 --network none \
  --cpus 4 --memory 30g --memory-swap 30g --pids-limit 512 \
  --mount "type=bind,src=$PWD,dst=/input,readonly" \
  --mount "type=bind,src=$PWD/.work,dst=/work" \
  talos-dgx-kernel/toolchain:local

# Build the corrected Talos userspace and assemble the ARM64 installer.
python3 package.py
```

Output: **`out/installer-arm64.tar`**, plus its SHA256 printed by `package.py`.
The packaging stage uses Talos's pinned Dockerfile/build targets and imager,
not a replacement OS build system. It does not publish or install anything.

Preparation deliberately refuses an existing source tree. To resume a failed
compilation, rerun the compilation command, not source preparation. To start a
new independent build, use a separate clone/work directory. Never copy the
entire `.work` directory into an image, repository, or release.

### What is pinned and checked

- Vendor source archives, NVIDIA/GDS downloads, final config, and ordered patches:
  `kernel/sources.json` and `kernel/series`.
- LLVM/tools container images and 58 Talos build-image references: immutable
  digests in `kernel/Toolchain.Dockerfile` and `talos/build.json`.
- Exact Talos source commit, version-constant/module-selection patch, installer
  profile, and NVIDIA extension recipe.
- Compilation checks kernel configuration/release, ARM64 image, BTF, module
  signatures against the embedded certificate, matching vermagic, and module
  dependency resolution. Packaging checks the selected modules and the resulting
  installer's architecture, embedded kernel, release, and default boot arguments.

Each work directory generates a **new private module-signing key**. It stays in
`.work/src/certs/signing_key.pem`; only its public certificate is embedded in the
kernel. Separate builds are therefore **not byte-identical**. Do not replace a
module independently with one signed by another build's key. UEFI Secure Boot
is disabled in this installer profile; kernel module-signature enforcement remains
on. Secure Boot enablement is outside this recipe.

## Publish and install

**No command in the build section changes a target machine.** Installation below
is a separate, explicitly chosen operation. Build once and use that installer on
multiple compatible Sparks; each keeps its own machine configuration and identity.

### Publish to your registry

Authenticate to your registry using its normal tooling, then substitute your own
repository in `IMAGE`. Do not commit registry credentials.

```sh
IMAGE=registry.example.com/your-project/talos-dgx-kernel:v1.14.1
docker load --input out/installer-arm64.tar
docker tag talos-dgx-kernel/installer:v1.14.1 "$IMAGE"
docker push "$IMAGE"
docker image inspect "$IMAGE" --format '{{json .RepoDigests}}'
```

Use the pushed **repository@sha256:digest** for installation. The node must be
able to pull it, including any private-registry authentication. A supported Talos
LAN image cache is an alternative; the example hostname above is only a placeholder.

### One node at a time

1. Confirm its hardware and compatibility with this Talos version. Back up its
   configuration and credentials **outside this repository**, and retain a
   known-good boot entry and console recovery path.
2. Identify the LAN NIC's permanent MAC. Select the interface independently of
   its driver name: the stock kernel used `r8169`, while this kernel uses `r8127`
   for RTL8127. Do not copy another machine's MAC, addresses, identity, or secrets.
3. Arrange workload draining and PodDisruptionBudgets. Upgrade only one node,
   verify it, then proceed to the next.

Example for an existing compatible Talos node, after those checks:

```sh
# Set these yourself; keep credentials outside the checkout.
export TALOSCONFIG=/secure/path/to/talosconfig
NODE=your-node-address
INSTALLER=registry.example.com/your-project/talos-dgx-kernel@sha256:YOUR_PUSHED_DIGEST

talosctl --nodes "$NODE" read /proc/sys/kernel/random/boot_id

# Stages the upgrade but does NOT drain or reboot the node.
talosctl --nodes "$NODE" upgrade --image "$INSTALLER" --no-reboot

# Restore any temporary delivery configuration before rebooting.
# This is the disruptive step: drain workloads, then perform a full powercycle.
talosctl --nodes "$NODE" reboot --mode powercycle --drain --wait

talosctl --nodes "$NODE" read /proc/version
talosctl --nodes "$NODE" read /proc/sys/kernel/random/boot_id
talosctl --nodes "$NODE" get linkstatus
talosctl --nodes "$NODE" get extensions
```

Require the expected kernel release, a new boot ID, working LAN/default route and
Talos API, Kubernetes Ready, and working NVIDIA GPU/CDI/CUDA before upgrading the
next node. Check that workloads are restored and the node is schedulable according
to your maintenance plan. If boot fails, recover through the retained known-good
boot entry using the console. **Do not use reset, wipe, or a fresh-install command
as an upgrade shortcut.** This guide covers upgrades, not blank-disk provisioning.

## Small checks without building

```sh
bash -n kernel/build.sh
python3 -m py_compile prepare.py package.py
python3 -m unittest discover -s tests -v
python3 package.py --plan
```

`--plan` makes no Docker calls or downloads. Tests use clearly marked fixtures;
they are not evidence that a new kernel was compiled or booted.

## Packaging differences from stock Talos

The vendor kernel supplies the Realtek `r8127` driver. Talos's module list must
explicitly include it. That list also omits five files the vendor build does not
produce: HKDF is built in; Intel firmware logging is inside `ice.ko`; `libeth_xdp`
is unselected; Allwinner Sun55i support is absent; Renesas RZ/N1 PCS is unselected.
The main `libeth`, `libie`, `ice`, `r8169`, and Mellanox modules remain.

The Talos kernel-version constant is rebuilt along with userspace. Do not create
a fake module-directory symlink or use a stock imager with the wrong release.

## Licenses

Kernel/vendor code and patches retain their upstream license notices (principally
GPL-2.0-only); Talos source changes are under its MPL-2.0 terms. Downloaded NVIDIA
proprietary components retain NVIDIA's license. This private repository does not
grant blanket redistribution rights over downloaded sources or generated images.
Review those component licenses before distributing binaries. No private signing
keys, cluster credentials, benchmark data, or investigation archives are included.
