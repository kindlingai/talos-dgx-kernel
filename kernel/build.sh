#!/bin/bash
# Inside Toolchain.Dockerfile only: /input:ro, private persistent /work.
# Prepare authenticated/patched sources in /work/{src,nvidia,gds} first.
# Outputs: /work/kernel-root and /work/nvidia-root. No image packaging or install.
# Allow at least 30 GiB RAM; JOBS controls compile/link concurrency (default 4).
set -euo pipefail
umask 077
export PATH=/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C TZ=UTC
fail() { printf 'build: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || fail 'No arguments; use JOBS to select parallelism.'
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail 'Native Linux AMD64 is required.'
[[ $(id -u) == 0 ]] || fail 'Run as root inside the toolchain container.'
jobs=${JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail 'JOBS must be a positive integer.'
for tool in make clang ld.lld llvm-strip llvm-objdump python3 openssl pahole modinfo depmod; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
python3 - <<'PY'
import hashlib, platform, re, subprocess
from pathlib import Path
# QEMU user emulation changes uname, but exposes the host's /proc/cpuinfo.
assert platform.machine() == 'x86_64'
assert re.search(r'^flags\s*:.*\blm\b', Path('/proc/cpuinfo').read_text(), re.M), 'AMD64 host CPU required; no emulation'
assert 'clang version 22.1.8' in subprocess.check_output(['clang', '--version'], text=True)
assert subprocess.check_output(['pahole', '--version'], text=True).strip() == 'v1.31'
assert hashlib.sha256(Path('/input/kernel/config').read_bytes()).hexdigest() == 'e294a58243d7675d4dc4eec460f224b49243c78303b959609f80fc7bb49a31c6', 'Unpinned kernel config'
for name in ['/work', '/work/src', '/work/nvidia/kernel', '/work/gds/src']:
    p = Path(name)
    assert p.is_dir() and p.resolve() == p, f'Missing or redirected source directory: {p}'
for name in ['/work/src/Makefile', '/work/src/debian/scripts/sign-module', '/work/gds/src/configure', '/input/kernel/x509.genkey']:
    assert Path(name).is_file(), f'Missing prepared input: {name}'
PY
chmod 700 /work /work/src
export ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-musl-
export PLATFORM=linux/arm64 INSTALLER_ARCH=targetarch
export KBUILD_BUILD_USER=talos KBUILD_BUILD_HOST=dgx-builder
export SOURCE_DATE_EPOCH=$(python3 -c 'import json; print(json.load(open("/input/kernel/sources.json"))["source_date_epoch"])')
export KBUILD_BUILD_TIMESTAMP=$(python3 -c 'import datetime,os; print(datetime.datetime.fromtimestamp(int(os.environ["SOURCE_DATE_EPOCH"]), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S +0000"))')
export KBUILD_BUILD_VERSION=1
# Make's command-line JOBS overrides Makefile.btf's inferred parallelism.
# Keep pahole single-threaded even when make and ThinLTO use several workers.
export MAKEFLAGS='JOBS=1'
linker="ld.lld --thinlto-cache-dir=/work/lto-cache --thinlto-jobs=$jobs --threads=$jobs"
kmake() { make -C /work/src -j"$jobs" LD="$linker" "$@"; }
export KVER=6.17.13-talos-dgx1022
cd /work/src
cp /input/kernel/config .config
cp /input/kernel/x509.genkey certs/x509.genkey
# The Debian source signing hook must be executable; do not alter its contents.
chmod u+x debian/scripts/sign-module
kmake olddefconfig
cmp .config /input/kernel/config || fail 'olddefconfig changed the pinned config.'
[[ $(kmake -s kernelrelease) == "$KVER" ]] || fail 'Unexpected kernel release.'
# Generate once per private workdir. Never copy this PEM into an output tree.
[[ ! -L certs/signing_key.pem && ! -L certs/signing_key.x509 ]] || fail 'Signing material must not be symlinks.'
if [[ ! -e certs/signing_key.pem ]]; then
    [[ ! -e certs/signing_key.x509 ]] || fail 'Certificate exists without its private key; use a fresh workdir.'
    openssl req -new -nodes -utf8 -sha512 -days 36500 -batch -x509 \
        -config certs/x509.genkey -outform PEM \
        -out certs/signing_key.pem -keyout certs/signing_key.pem
fi
chmod 600 certs/signing_key.pem
kmake vmlinuz.efi
kmake modules
kmake DTC_FLAGS=-@ dtbs
[[ -s vmlinux && -s Module.symvers && -s System.map ]] || fail 'Incomplete kernel build.'
[[ $(<include/config/kernel.release) == "$KVER" ]] || fail 'Kernel release drift.'
private_public=$(openssl pkey -in certs/signing_key.pem -pubout -outform DER | sha256sum)
certificate_public=$(openssl x509 -inform DER -in certs/signing_key.x509 -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
[[ $private_public == "$certificate_public" ]] || fail 'Signing key and certificate disagree.'
# Parse the final image's BTF, not an intermediate object's debug information.
pahole -F btf vmlinux >/dev/null

# External conftests also need an explicit AArch64 target outside Kbuild.
make -C /work/nvidia/kernel -j"$jobs" CC='clang --target=aarch64-linux-musl' \
    LD="$linker" OBJDUMP=llvm-objdump SYSSRC=/work/src SYSOUT=/work/src
mkdir -p "/lib/modules/$KVER"
ln -sfn /work/src "/lib/modules/$KVER/build"
cd /work/gds/src
# Bound only the vendor configure script's two hardcoded make probes.
python3 - "$jobs" <<'PY'
import re, sys
from pathlib import Path
p = Path('configure')
s, count = re.subn(r'\bmake -j[0-9]+\b', 'make -j' + sys.argv[1], p.read_text())
assert count == 2, f'Unexpected GDS configure probes: {count}'
p.write_text(s)
PY
CC='clang --target=aarch64-linux-musl' ./configure "$KVER"
GDS_VERSION=$(<GDS_VERSION)
kmake M=/work/gds/src modules KDIR=/work/src \
    NVIDIA_SRC_DIR=/work/nvidia/kernel/nvidia \
    KBUILD_EXTRA_SYMBOLS=/work/nvidia/kernel/Module.symvers \
    KCPPFLAGS="-DCONFIG_NVFS_STATS=y -DGDS_VERSION=$GDS_VERSION -DNVFS_ENABLE_KERN_RDMA_SUPPORT -DNVFS_BATCH_SUPPORT=y" \
    KCFLAGS=-Wno-strict-prototypes CONFIG_NVFS_STATS=y CONFIG_NVFS_BATCH_SUPPORT=y

# Recreate only our staging roots. The source and its private key stay in place.
python3 - <<'PY'
from pathlib import Path
import shutil
for name in ['kernel-root', 'nvidia-root', 'combined-root']:
    p = Path('/work') / name
    assert not p.is_symlink(), f'Redirected staging root: {p}'
    if p.exists():
        shutil.rmtree(p)
    p.mkdir(mode=0o755)
PY
mkdir -p /work/kernel-root/boot
cp /work/src/arch/arm64/boot/vmlinuz.efi /work/kernel-root/boot/vmlinuz
cp /work/src/System.map /work/kernel-root/boot/System.map
# modules_install strips first, then signs with CONFIG_MODULE_SIG_HASH=sha512.
# Delay depmod until the matching native and external modules are together.
kmake modules_install INSTALL_MOD_PATH=/work/kernel-root/usr INSTALL_MOD_STRIP=1 DEPMOD=true
make -C /work/nvidia/kernel -j"$jobs" CC='clang --target=aarch64-linux-musl' \
    LD="$linker" OBJDUMP=llvm-objdump modules_install SYSSRC=/work/src SYSOUT=/work/src \
    INSTALL_MOD_PATH=/work/nvidia-root/usr INSTALL_MOD_DIR=extras INSTALL_MOD_STRIP=1 DEPMOD=true
kmake M=/work/gds/src modules_install INSTALL_MOD_PATH=/work/nvidia-root/usr \
    INSTALL_MOD_DIR=extras INSTALL_MOD_STRIP=1 DEPMOD=true

python3 - <<'PY'
import hashlib, json, mmap, os, shutil, struct, subprocess, tempfile, uuid
from datetime import datetime, timezone
from pathlib import Path

root, src = Path('/work'), Path('/work/src')
release = os.environ['KVER']
kernel, external = root / 'kernel-root', root / 'nvidia-root'
native = kernel / 'usr/lib/modules' / release
extra = external / 'usr/lib/modules' / release
assert (src / '.config').read_bytes() == Path('/input/kernel/config').read_bytes(), 'Config drift'
cert = src / 'certs/signing_key.x509'
assert (src / 'certs/signing_key.pem').stat().st_mode & 0o077 == 0
with (src / 'vmlinux').open('rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as elf:
    assert elf[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', elf, 18)[0] == 183
    assert elf.find(cert.read_bytes()) >= 0, 'Public signing certificate absent from vmlinux'
    shoff = struct.unpack_from('<Q', elf, 40)[0]
    size, count, strings = struct.unpack_from('<HHH', elf, 58)
    assert size == 64 and count > 0
    sections = [struct.unpack_from('<IIQQQQIIQQ', elf, shoff + i * size) for i in range(count)]
    names = sections[strings]
    names = elf[names[4]:names[4] + names[5]]
    btf = next(s for s in sections if names[s[0]:].split(b'\0', 1)[0] == b'.BTF')
    assert btf[5] > 24
    magic, version, flags, hdr, toff, tlen, soff, slen = struct.unpack_from('<HBBIIIII', elf, btf[4])
    assert magic == 0xeb9f and version == 1 and hdr >= 24 and tlen > 0 and slen > 1
    assert hdr + toff + tlen <= btf[5] and hdr + soff + slen <= btf[5]
with (kernel / 'boot/vmlinuz').open('rb') as f:
    pe = f.read(4096)
    offset = struct.unpack_from('<I', pe, 60)[0]
    assert pe[:2] == b'MZ' and pe[offset:offset + 4] == b'PE\0\0'
    assert struct.unpack_from('<H', pe, offset + 4)[0] == 0xaa64, 'Not an ARM64 EFI image'
dtbs = sorted((src / 'arch/arm64/boot/dts').rglob('*.dtb'))
assert dtbs, 'No compiled device trees'
for dtb in dtbs:
    target = kernel / 'dtb' / dtb.relative_to(src / 'arch/arm64/boot/dts')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dtb, target)
# Never copy src/modules.order: that contains internal .o paths on this kernel.
order = (native / 'modules.order').read_text().splitlines()
assert order and all(p.endswith('.ko') and (native / p).is_file() for p in order)
for name in ['modules.order', 'modules.builtin', 'modules.builtin.modinfo']:
    shutil.copy2(native / name, extra / name)
for tree in [kernel, external]:
    for p in tree.rglob('*'):
        if p.is_symlink() and p.name in {'build', 'source'}:
            p.unlink()
    assert not any(p.is_symlink() for p in tree.rglob('*')), 'Unexpected runtime symlink'

# Check every installed module against THIS workdir's certificate and vermagic.
# CMS -nointern forbids using a foreign certificate embedded in the signature.
# -noverify skips certificate-chain trust, not cryptographic content verification.
native_modules, external_modules = sorted(native.rglob('*.ko')), sorted(extra.rglob('*.ko'))
assert native_modules
assert {p.name for p in external_modules} == {'nvidia.ko', 'nvidia-uvm.ko', 'nvidia-modeset.ko', 'nvidia-drm.ko', 'nvidia-peermem.ko', 'nvidia-fs.ko'}
assert len(external_modules) == 6
vermagic = None
signature_magic = b'~Module signature appended~\n'
with tempfile.TemporaryDirectory(prefix='verify-', dir=root) as tmp:
    tmp = Path(tmp)
    public, payload, signature = tmp / 'public.pem', tmp / 'payload', tmp / 'signature.der'
    subprocess.run(['openssl', 'x509', '-inform', 'DER', '-in', str(cert), '-out', str(public)], check=True)
    for module in native_modules + external_modules:
        data = module.read_bytes()
        assert data[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', data, 18)[0] == 183, module
        assert data.endswith(signature_magic), f'Unsigned module: {module}'
        end = len(data) - len(signature_magic) - 12
        algo, hash_id, kind, signer_len, key_len, padding, length = struct.unpack('>BBBBB3sI', data[end:end + 12])
        assert kind == 2 and signer_len == key_len == 0 and padding == b'\0\0\0' and 0 < length < end
        payload.write_bytes(data[:end - length])
        signature.write_bytes(data[end - length:end])
        checked = subprocess.run(['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', str(signature), '-content', str(payload), '-certfile', str(public), '-nointern', '-noverify', '-out', os.devnull], capture_output=True)
        assert checked.returncode == 0, f'Invalid signature: {module}: {checked.stderr.decode()}'
        def field(name):
            return subprocess.check_output(['modinfo', '-F', name, str(module)], text=True).strip()
        current = field('vermagic')
        assert current.split()[0] == release and (vermagic is None or current == vermagic), module
        vermagic = current
        assert field('sig_hashalgo') == 'sha512', module
        if module.name == 'nvidia.ko':
            assert field('version') == '580.178.04' and field('license') == 'NVIDIA'

# Native depmod is useful to downstream packagers; combined depmod proves closure.
def depmod(tree):
    result = subprocess.run(['depmod', '-b', str(tree / 'usr'), '-F', str(src / 'System.map'), '--errsyms', '-w', release], capture_output=True, text=True)
    assert result.returncode == 0 and not result.stdout and not result.stderr, 'depmod must be silent: ' + result.stdout + result.stderr

depmod(kernel)
combined = root / 'combined-root'
shutil.copytree(kernel / 'usr/lib/modules', combined / 'usr/lib/modules')
for module in external_modules:
    target = combined / 'usr/lib/modules' / release / module.relative_to(extra)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(module, target)
depmod(combined)
shutil.rmtree(combined)

# SPDX describes actual staged runtime files; source and private keys are excluded.
# Keys and X.509 validity dates make separate workdirs intentionally non-identical.
for tree, name, version, license_id in [(kernel, 'kernel', release, 'GPL-2.0-only'), (external, 'kmod-nvidia-lts', '580.178.04', 'NOASSERTION')]:
    files, sha1s = [], []
    for p in sorted(p for p in tree.rglob('*') if p.is_file()):
        rel = p.relative_to(tree).as_posix()
        allowed = (rel in {'boot/vmlinuz', 'boot/System.map'} or rel.startswith('dtb/') and rel.endswith('.dtb') or rel.startswith('usr/lib/modules/' + release + '/') and (p.suffix == '.ko' or p.name.startswith('modules.')))
        assert allowed, f'Unexpected runtime file: {p}'
        data = p.read_bytes()
        assert b'-----BEGIN PRIVATE KEY-----' not in data and b'-----BEGIN RSA PRIVATE KEY-----' not in data
        sha1, sha256 = hashlib.sha1(data).hexdigest(), hashlib.sha256(data).hexdigest()
        sha1s.append(sha1)
        files.append({'fileName': './' + rel, 'SPDXID': f'SPDXRef-File-{len(files)}', 'checksums': [{'algorithm': 'SHA1', 'checksumValue': sha1}, {'algorithm': 'SHA256', 'checksumValue': sha256}], 'licenseConcluded': 'NOASSERTION', 'licenseInfoInFiles': ['NOASSERTION'], 'copyrightText': 'NOASSERTION'})
    code = hashlib.sha1(''.join(sorted(sha1s)).encode()).hexdigest()
    package = 'SPDXRef-Package-' + name
    sbom = {'spdxVersion': 'SPDX-2.3', 'dataLicense': 'CC0-1.0', 'SPDXID': 'SPDXRef-DOCUMENT', 'name': name, 'documentNamespace': 'urn:uuid:' + str(uuid.uuid5(uuid.NAMESPACE_URL, name + version + code)), 'creationInfo': {'creators': ['Tool: talos-dgx-kernel'], 'created': datetime.fromtimestamp(int(os.environ['SOURCE_DATE_EPOCH']), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}, 'packages': [{'name': name, 'SPDXID': package, 'versionInfo': version, 'downloadLocation': 'NOASSERTION', 'filesAnalyzed': True, 'packageVerificationCode': {'packageVerificationCodeValue': code}, 'licenseConcluded': 'NOASSERTION', 'licenseDeclared': license_id, 'copyrightText': 'NOASSERTION'}], 'files': files, 'relationships': [{'spdxElementId': 'SPDXRef-DOCUMENT', 'relationshipType': 'DESCRIBES', 'relatedSpdxElement': package}] + [{'spdxElementId': package, 'relationshipType': 'CONTAINS', 'relatedSpdxElement': f['SPDXID']} for f in files]}
    target = tree / 'usr/share/spdx' / (name + '.spdx.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(sbom, indent=2) + '\n')
    tree.chmod(0o755)
    for p in tree.rglob('*'):
        p.chmod(0o755 if p.is_dir() else 0o644)
print(f'Staged {release}: {len(native_modules)} native modules, {len(external_modules)} NVIDIA/GDS modules, {len(dtbs)} DTBs; SHA512 signatures, BTF, vermagic and silent combined depmod passed.')
print('Static build checks only; no module loaded, kernel booted, or system installed.')
PY
