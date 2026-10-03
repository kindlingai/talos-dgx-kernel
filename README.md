# Talos DGX kernel

Talos **v1.14.1** for NVIDIA DGX Spark (arm64), release **v1.14.1-dgx1022.7**.
Linux sources remain Ubuntu `linux-nvidia-6.17` 6.17.0-1022.22 plus the pinned
`kernel/patches/series`. NVIDIA stays **580.178.04** and GPUDirect Storage stays
**2.29.4**. The toolchain, security config, BTF, and signing checks remain enabled.
`.7` keeps `.6`'s kernel and driver inputs. It changes only the release string and
fixes nvidia-persistenced and nvidia-cdi-gen startup (see below).

## Installer choices

| Variant | CPU pages | Kernel release | NVIDIA source |
| --- | --- | --- | --- |
| `proprietary-4k` | 4 KiB | `6.17.13-talos-dgx1022.7-4k` | archive `kernel/` |
| `open-4k` | 4 KiB | `6.17.13-talos-dgx1022.7-4k` | archive `kernel-open/` |
| `open-64k` | 64 KiB | `6.17.13-talos-dgx1022.7-64k` | archive `kernel-open/` |

The two 4 KiB installers share the **same built kernel**, Talos installer base,
and imager. Only their NVIDIA/GDS extension differs. The 64 KiB kernel is built
separately, once. Driver and page size are installer-time choices, not a runtime
page-size switch. `proprietary-64k` is rejected by Make, Bake, and the module script.
There is no packing-off build variant and no unsuffixed `.7` image alias.

Both open variants apply the same two patches in the same order:

- **HUB ATS CUDA workaround**, by Matt Mastracci:
  `0001-nvidia-uvm-flush-gpu-tlb-after-hub-ats-faults.patch` invalidates GPU TLBs
  after servicing copy-engine ATS faults. This avoids stale entries on 64 KiB
  kernels during pageable-memory CUDA copies.
- **GPU leaf-table packing**, by Christopher Owen:
  `0002-nvidia-uvm-pack-user-leaf-page-tables.patch`, from
  [dgx-spark-memory-saver](https://github.com/christopherowen/dgx-spark-memory-saver),
  packs small user leaf tables into shared CPU pages on coherent integrated
  GPUs. It is enabled by default and inert on 4 KiB kernels. Both patches are
  mandatory in the open build script; the proprietary source is not patched.

Each extension builds GDS against the matching driver's `Module.symvers` and
headers. Open extensions use `nvidia-open-gpu-kernel-modules-lts`; proprietary
uses `nvidia-gpu-kernel-modules-lts`. Manifests and SPDX documents name the variant.
All installers also include the same [dispram service](dispram/README.md) and
`nvidia-container-toolkit-lts` extension. The toolkit extension is the pinned Sidero
Labs image with two startup fixes, built from `toolkit/`:

- **nvidia-persistenced waits for the driver and is restarted when it fails.**
  Talos starts the service when `/sys/bus/pci/drivers/nvidia` appears. That happens
  partway through `nvidia_init_module()`, seconds before the driver registers
  `/dev/nvidiactl`. Started that early, nvidia-persistenced fails to initialize and
  removes `/run/nvidia-persistenced`. The upstream wrapper still never exits, so
  `restart: always` never retries. `toolkit/nvidia-persistenced-wrapper.c` waits for
  `nvidiactl` in `/proc/devices`, which the driver registers last. It then
  supervises the daemon and exits non-zero if the daemon fails or dies.
  Gating on `/dev/nvidiactl` would not work, because the upstream udev rule creates
  the node as soon as the PCI driver directory appears.
- **nvidia-cdi-gen waits for `/run/nvidia-persistenced/socket`.** It bind-mounts
  the nvidia-persistenced state directory, so it previously failed with "no such
  file or directory" on boots where nvidia-persistenced had not initialized. Then
  Kubernetes never saw the GPU.

Runtime behavior of newly built variants still needs separate boot/CUDA validation.

## Kernel config policy

- `kernel/config-4k` is the `.1` tag's full config, with only `CONFIG_LOCALVERSION`
  changed to `-talos-dgx1022.7-4k`.
- `kernel/config-64k` is the `.5` full config, with only `CONFIG_LOCALVERSION`
  changed to `-talos-dgx1022.7-64k`.
- The page configs retain their existing dependent page geometry and Kconfig
  availability differences. These include page shifts, page-table levels,
  address randomization limits, huge-page sharing/swap features, and drivers
  unavailable with 64 KiB pages. No unrelated tuning is added.
- **CMA policy is deliberately unchanged:** 128 MiB for 4 KiB, 1024 MiB for
  64 KiB, matching the previous builds and Ubuntu's `nvidia-64k` policy.
  This reservation difference must be accounted for in page-size comparisons.
- Full `olddefconfig` equality is required during each real build. Offline tests
  also hash both configs against the historical baselines, excluding only the
  release string. They do not replace the toolchain's Kconfig check.

64 KiB pages reduce page-descriptor overhead, but also increase minimum allocation
size and PMD-level huge-page size. Applications and allocators that assume 4 KiB
pages need compatible builds. Recreate swap areas under the selected kernel.

## Build

Requirements: Docker with buildx, GNU Make, Bash, Git, OpenSSL, and Python 3.
The build uses all builder CPUs; allow sufficient memory for BTF and disk for
both complete Kbuild trees, Talos builds, OCI exports, and all six boot artifacts.
CI uses the existing 16-vCPU Blacksmith arm64 runner and a 360-minute limit.

Use the **existing trusted module signing key**, not a fresh key for each variant:

```sh
make SIGNING_KEY=/secure/path/module-signing.pem    # all three choices
make variant VARIANT=open-4k SIGNING_KEY=/secure/path/module-signing.pem
make test                                         # offline contracts, no compilation
make print-variant VARIANT=proprietary-4k
```

For a new, separate trust domain only, `make signing-key` creates
`keys/module-signing.pem`. CI reads the repository's `MODULE_SIGNING_KEY` secret,
uses a mode-0600 temporary file, and removes it afterward. The key is never copied
into a layer, compiler cache, or uploaded artifact. `CONFIG_MODULE_SIG_KEY` stays
`/run/secrets/module_signing_key`. All kernel, NVIDIA, and GDS modules use it.

`make` runs these stages in order, even under `make -j`:

1. Build the common dispram and nvidia-container-toolkit-lts extensions.
2. Build/export the 4 KiB kernel and its Talos installer base/imager.
3. Package the proprietary 4 KiB extension, installer, and ISO.
4. Package the open 4 KiB extension, installer, and ISO using the same kernel export.
5. Build/export the 64 KiB kernel and its Talos installer base/imager.
6. Package the open 64 KiB extension, installer, and ISO.
7. Record provenance and verify the complete artifact/checksum matrix.

`make kernel VARIANT=...` and `make talos VARIANT=...` are bounded intermediate
steps. `package`, `installer`, and `iso` are internal assembly steps, not standalone
build entry points. `package` rejects stale shared-kernel exports, including a
changed signing certificate. No automatic whole-checkout cleanup is performed.

### Persistent compiler reuse

CI pins Blacksmith `setup-docker-builder` v2.2.0 by commit and uses the stable
`talos-dgx-arm64-buildkit-v1` cache key with `nofallback: true`. BuildKit remains
v0.33.1; the local builder retains its existing digest pin. The action selects a
remote builder, which Make uses directly. CI verifies its name, driver, and
`/var/lib/buildkit` mount; Make refuses to create a substitute builder.

Blacksmith persists **layers and cache mounts** after successful jobs. The first
run is cold, and failed jobs do not commit new cache state. The immutable
`kernel-build` layer retains the entire compiled Kbuild tree, including
`Module.symvers`, for subsequent driver builds and runs. Module-only scripts,
extension patches, manifests, and imager profiles do not invalidate Linux inputs.
Linux and NVIDIA downloads are separate dependencies, and script mounts are narrow.

A shared mutable Kbuild output directory is deliberately not used. Generated
headers, source timestamps, and signing state must not leak across kernel inputs.
Changed Linux inputs rebuild the stage. LLVM's content-addressed **ThinLTO cache**
can reuse compilation work, partitioned by target architecture, page geometry,
and the pinned LLVM/tools identity. No private-key bytes enter that cache.

BuildKit secrets do not invalidate caches by themselves. The signing certificate's
public DER SHA-256 is an explicit kernel-stage argument and provenance field.
Both kernel and module scripts verify the secret's certificate ID and key pair.
Rotation therefore invalidates signed layers without exporting the private key.

Plain CI logs show `CACHED` stages and ThinLTO cache size before/after uncached
kernel steps. Builder identity and cache usage are printed before/after the build.
`make cache-usage BUILDER=<name>` reports the selected builder's cache usage.
These controls are not a measured speedup: verify warm-run timings and Blacksmith's
successful cache-commit log in real CI.

### Talos source adaptation

Each page size gets a separate checkout of pinned Talos commit
`2f86b9d2a29b413deddd7122a8420b8913813615` under `.work/talos-<page>`.
`talos/source.patch` applies common initramfs module-list changes: add `r8127`;
remove `hkdf`, `libeth_xdp`, `libie_fwlog`, `dwmac-sun55i`, and `pcs-rzn1-miic`.
`scripts/prepare-talos.py` then sets the exact page-qualified
`DefaultKernelVersion`. It retains `vmxnet3` for 4 KiB and removes it for 64 KiB,
matching the actual kernel configs. Upstream constant/list mismatches fail closed.

## Outputs and provenance

The release assets under `_out/` are exactly:

```text
installer-arm64-proprietary-4k.tar
installer-arm64-open-4k.tar
installer-arm64-open-64k.tar
metal-arm64-proprietary-4k.iso
metal-arm64-open-4k.iso
metal-arm64-open-64k.iso
SHA256SUMS
OCI-DIGESTS
VARIANTS.json
```

`SHA256SUMS` covers all six artifacts plus `OCI-DIGESTS` and `VARIANTS.json`.
`VARIANTS.json` records driver/source selection, page size, releases, source commit,
config and patch hashes, public certificate ID, artifact hashes, and OCI digests.
Verification requires exactly all three choices, the shared 4 KiB kernel and
installer-base digest, different page-kernel digests, identical open patch sets,
and one certificate across all variants. Missing, stale, or altered files fail.

Local OCI layouts are kept separately:

- `_out/oci/kernels/{4k,64k}`
- `_out/oci/talos/{4k,64k}/installer-base`
- `_out/oci/variants/<variant>/nvidia-extension`
- `_out/oci/common/dispram-extension`
- `_out/oci/common/toolkit-extension`

`uname -v` begins with the kernel input fingerprint. The hash covers the selected
config, kernel patches, marked Linux Dockerfile stages/frontend pin, and kernel
scripts. It excludes module and installer packaging. Kernel releases explicitly
end in `-4k` or `-64k`; the release tag is explicitly `v1.14.1-dgx1022.7`, never
derived from the final kernel-release component.

The pinned inputs and `SOURCE_DATE_EPOCH` are unchanged. As before, the Talos
imager records wall-clock timestamps in installers and extension archives.
`SHA256SUMS` identifies one run's exact files; compare `OCI-DIGESTS` between runs
for reproducibility. Existing releases are not replaced by newly timed tarballs.

## CI and publication

- Manual **branch** dispatch of `build.yaml` builds all choices and uploads the
  nine release assets. It does **not** publish.
- Pushing the explicit `.7` version tag starts the same build, creates a GitHub
  release if absent, and calls `publish.yaml` once. The tag need not be on `main`.
- If the release already exists, CI compares its `OCI-DIGESTS` and uses the
  existing release artifacts. It does not overwrite them.
- `publish.yaml` has only `workflow_call` and explicit `workflow_dispatch`
  triggers. No competing `release:published` trigger exists.
- The publisher downloads all three installers and both metadata files, checks
  their hashes and matrix, and preflights every destination tag before any push.
  An existing different digest, authentication failure, or unknown lookup error
  stops publication. Each pushed tag is read back and checked.
- Publication serializes by release tag, records labeled digest references in
  the release notes, and reads those notes back to verify the update.

The image tags are:

```text
ghcr.io/kindlingai/talos-dgx-kernel/installer:v1.14.1-dgx1022.7-proprietary-4k
ghcr.io/kindlingai/talos-dgx-kernel/installer:v1.14.1-dgx1022.7-open-4k
ghcr.io/kindlingai/talos-dgx-kernel/installer:v1.14.1-dgx1022.7-open-64k
```

There is **no unsuffixed alias**. Existing `.5` and `.6` tags are outside this branch's
publication scope. `make release` requires an existing Git tag and refuses to
replace a release. `make push IMAGE=<registry/repository>` applies the same
three suffixes and no-overwrite checks. It requires registry authentication.
Review the branch and actual CI artifacts before tagging or publishing.

## Install and runtime verification

Choose the matching ISO or installer tag, then pin the published image digest in
`machine.install.image` or `talosctl upgrade --image`. For example:

```yaml
machine:
  install:
    image: ghcr.io/kindlingai/talos-dgx-kernel/installer:v1.14.1-dgx1022.7-open-64k@sha256:<published-digest>
```

When packages are private, configure `machine.registries.config` credentials.
Keep a configuration backup and console recovery path before changing a node.
Runtime acceptance is separate: verify the page-qualified kernel release,
`uname -v`, page size, extensions, networking, Kubernetes readiness, and CUDA/GDS
workloads. A successful build or publication does not prove any of those checks.

The Realtek LAN driver is `r8127`. The existing machine interface configuration
and kernel arguments are unchanged by variant selection.

## Tests and updates

`make test` uses stdlib unit tests, small explicit fixtures, temporary test
certificates, and the real `docker buildx bake --print` parser when installed.
It never compiles a kernel or runs an imager. Publication tests mock registry
commands and do not access a registry. Workflow syntax can be checked with:

```sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7 -shellcheck= -pyflakes= .github/workflows/*.yaml
```

For future releases, update the explicit release constants in Make, scripts,
configs, workflows, manifests, SPDX namespaces, tests, and this documentation.
When changing a toolchain pin, update its ThinLTO cache partition identity too.
Always retain full `olddefconfig`, SHA-512 signatures, vermagic, symbol-resolution,
and Talos extension validation. Do not trade those checks for cache hits.

## Licenses

Linux sources and patches keep their upstream license notices, principally
GPL-2.0-only. Talos changes follow MPL-2.0. NVIDIA open kernel modules are dual
MIT/GPL-2.0. The proprietary driver and the toolkit's user-space components carry
NVIDIA license terms. Their SPDX files do not label proprietary modules as open
source. Review the licenses from the pinned archives before distribution.
