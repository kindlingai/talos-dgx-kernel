#!/usr/bin/env python3
"""Fetch SHA256-locked inputs and reconstruct the admitted kernel source."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fetch(record, downloads):
    target = downloads / record['filename']
    if target.exists():
        require(sha256(target) == record['sha256'], f'Cached download checksum mismatch: {target}')
        print(f'Verified {target.name}', flush=True)
        return target
    print(f'Downloading {target.name}', flush=True)
    partial = target.with_name(target.name + '.partial')
    with urllib.request.urlopen(record['url'], timeout=90) as response, partial.open('wb') as output:
        shutil.copyfileobj(response, output, 1024 * 1024)
    require(sha256(partial) == record['sha256'], f'Download checksum mismatch: {target.name}')
    partial.replace(target)
    return target


def apply_patch(source, patch):
    for dry in (True, False):
        command = ['patch', '--batch', '--forward', '--fuzz=0', '-p1']
        if dry:
            command.append('--dry-run')
        with patch.open('rb') as stream:
            subprocess.run(command, cwd=source, stdin=stream, check=True)


def extract(archive, destination):
    destination.mkdir(mode=0o700)
    # Inputs were checked against committed hashes before invoking GNU tar.
    subprocess.run(['tar', '--extract', '--file', str(archive), '--strip-components=1',
                    '--no-same-owner', '--directory', str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.work', help='Private Linux work directory')
    parser.add_argument('--download-only', action='store_true', help='Fetch and verify inputs without extracting')
    options = parser.parse_args()
    os.umask(0o077)
    work = options.work.resolve()
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    downloads = work / 'download'
    downloads.mkdir(exist_ok=True, mode=0o700)
    lock = json.loads((ROOT / 'kernel/sources.json').read_text())
    require(sha256(ROOT / 'kernel/config') == lock['config_sha256'], 'Kernel config checksum mismatch')
    series = (ROOT / 'kernel/series').read_text().splitlines()
    require(series == [p['file'] for p in lock['patches']], 'Patch ordering differs from lock')
    for patch in lock['patches']:
        require(Path(patch['file']).name == patch['file'], 'Invalid patch filename')
        require(sha256(ROOT / 'kernel/patches' / patch['file']) == patch['sha256'],
                f"Patch checksum mismatch: {patch['file']}")
    archives = {record['filename']: fetch(record, downloads) for record in lock['downloads']}
    if options.download_only:
        print('All source downloads and repository inputs verified.', flush=True)
        return
    require(platform.system() == 'Linux', 'Source preparation requires Linux and GNU tar; use the toolchain container.')
    for name in ('src', 'nvidia', 'gds'):
        require(not (work / name).exists(), f'{work / name} already exists; use a fresh work directory. Downloads may be reused.')
    # A failed attempt leaves no partially prepared final source trees.
    with tempfile.TemporaryDirectory(prefix='prepare-', dir=work) as temporary:
        stage = Path(temporary)
        source = stage / 'src'
        extract(archives['linux-nvidia-6.17_6.17.0.orig.tar.gz'], source)
        delta = stage / 'vendor.patch'
        with gzip.GzipFile(filename=archives['linux-nvidia-6.17_6.17.0-1022.22.diff.gz'], mode='rb') as stream, delta.open('wb') as output:
            shutil.copyfileobj(stream, output)
        apply_patch(source, delta)
        delta.unlink()
        for name in series:
            print(f'Applying {name}', flush=True)
            apply_patch(source, ROOT / 'kernel/patches' / name)
        extract(archives['nvidia-580.178.04.tar.xz'], stage / 'nvidia')
        extract(archives['gds-v2.29.4.tar.gz'], stage / 'gds')
        shutil.copy2(ROOT / 'kernel/config', source / '.config')
        shutil.copy2(ROOT / 'kernel/x509.genkey', source / 'certs/x509.genkey')
        signing = source / 'debian/scripts/sign-module'
        require(sha256(signing) == '712d7ad2c2e92ef519d06c51bfa16aa1d499dfb73880cc3d8c40bbba97a7f549',
                'Unexpected vendor signing helper')
        signing.chmod(0o700)
        for name in ('src', 'nvidia', 'gds'):
            (stage / name).rename(work / name)
    print('Prepared pinned kernel, NVIDIA, and GDS sources. No compilation or installation performed.', flush=True)


if __name__ == '__main__':
    main()
