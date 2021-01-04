#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: with ps; [ toml requests ])"
import base64
import json
import re
import string
import sys
import time
import datetime
from pathlib import Path

import toml
import requests

MAX_TRIES = 3
RETRY_DELAY = 3.0
SYNC_MAX_FETCH = 5

MIN_STABLE_VERSION = '1.29.0'
MIN_NIGHTLY_DATE = datetime.date.fromisoformat('2018-09-13')

DIST_ROOT = 'https://static.rust-lang.org/dist'
NIX_KEYWORDS = {'', 'if', 'then', 'else', 'assert', 'with', 'let', 'in', 'rec', 'inherit', 'or'}
MANIFEST_TMP_PATH = Path('manifest.tmp')
TARGETS_PATH = Path('manifests/targets.nix')
RENAMES_PATH = Path('manifests/renames.nix')

RE_STABLE_VERSION = re.compile(r'^\d+\.\d+\.\d+$')

def to_base64(hash: str) -> str:
    assert len(hash) == 64
    return base64.b64encode(bytes.fromhex(hash)).decode()

def is_valid_nix_ident(name: str) -> bool:
    return name not in NIX_KEYWORDS and \
        (name[0] == '_' or name[0].isalpha()) and \
        all(c in "_-'" or c.isalnum() for c in name)

def escape_nix_string(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def escape_nix_key(name: str) -> str:
    if is_valid_nix_ident(name):
        return name
    return escape_nix_string(name)

def parse_version(ver: str) -> tuple:
    return tuple(map(int, ver.split('.')))

def version_less(a: str, b: str):
    return parse_version(a) < parse_version(b)

target_map = dict((line.split('"')[1], i) for i, line in enumerate(TARGETS_PATH.read_text().strip().split('\n')[1:-1]))
def compress_target(target: str) -> str:
    assert '"' not in target
    if target == '*':
        return '_'
    if target in target_map:
        return f'_{target_map[target]}'
    idx = len(target_map)
    target_map[target] = idx

    with open(str(TARGETS_PATH), 'w') as f:
        f.write('{\n')
        for i, target in sorted((v, k) for k, v in target_map.items()):
            f.write(f'  _{i} = "{target}";\n')
        f.write('}\n')
    return f'_{idx}'

renames_map = dict((line.strip(), i) for i, line in enumerate(RENAMES_PATH.read_text().strip().split('\n')[1:-1]))
def compress_renames(renames: dict) -> int:
    serialized = '{ ' + ''.join(
        f'{escape_nix_key(k)} = {escape_nix_string(v["to"])}; '
        for k, v in sorted(renames.items())
    ) + '}'

    if serialized in renames_map:
        return renames_map[serialized]
    idx = len(renames_map)
    renames_map[serialized] = idx

    with open(str(RENAMES_PATH), 'w') as f:
        f.write('[\n')
        for _, ser in sorted((idx, ser) for ser, idx in renames_map.items()):
            f.write('  ' + ser + '\n')
        f.write(']\n')
    return idx

def retry_with(f):
    i = 0
    while True:
        try:
            return f()
        except requests.exceptions.RequestException as e:
            i += 1
            if i >= MAX_TRIES:
                raise
            print(e)
            time.sleep(RETRY_DELAY)

def translate_dump_manifest(manifest: str, f, nightly=False):
    manifest = toml.loads(manifest)
    date = manifest['date']
    rustc_version = manifest['pkg']['rustc']['version'].split()[0]
    renames_idx = compress_renames(manifest['renames'])
    strip_tail = '-preview'

    f.write('{')
    f.write(f'v={escape_nix_string(rustc_version)};')
    f.write(f'd={escape_nix_string(date)};')
    f.write(f'r={renames_idx};')
    for pkg_name in sorted(manifest['pkg'].keys()):
        pkg = manifest['pkg'][pkg_name]
        pkg_name_stripped = pkg_name[:-len(strip_tail)] if pkg_name.endswith(strip_tail) else pkg_name
        pkg_targets = sorted(pkg['target'].keys())

        url_version = rustc_version
        for target_name in pkg_targets:
            target = pkg['target'][target_name]
            if not target['available']:
                continue
            url = target['xz_url']
            target_tail = '' if target_name == '*' else '-' + target_name
            start = f'{DIST_ROOT}/{date}/{pkg_name_stripped}-'
            end = f'{target_tail}.tar.xz'
            # Occurs in nightly-2019-01-10. Maybe broken or hirarerchy change?
            if url.startswith('nightly/'):
                url = DIST_ROOT + url[7:]
            assert url.startswith(start) and url.endswith(end), f'Unexpected url: {url}'
            url_version = url[len(start):-len(end)]

        f.write(f'{pkg_name}={{')
        if not (url_version == rustc_version or (url_version == 'nightly' and nightly)):
            f.write(f'u={escape_nix_string(url_version)};')
        for target_name in pkg_targets:
            target = pkg['target'][target_name]
            if not target['available']:
                continue
            url = target['xz_url']
            # See above.
            if url.startswith('nightly/'):
                url = DIST_ROOT + url[7:]
            hash = to_base64(target['xz_hash']) # Hash must not contains quotes.
            target_tail = '' if target_name == '*' else '-' + target_name
            expect_url = f'https://static.rust-lang.org/dist/{date}/{pkg_name_stripped}-{url_version}{target_tail}.tar.xz'
            assert url == expect_url, f'Unexpected url: {url}, expecting: {expect_url}'
            f.write(f'{compress_target(target_name)}="{hash}";')
        f.write('};')
    f.write('}\n')

def fetch_stable_manifest(version: str, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix('.tmp')
    print(f'Fetching stable {version}')
    manifest = retry_with(lambda: requests.get(f'{DIST_ROOT}/channel-rust-{version}.toml'))
    manifest.raise_for_status()
    manifest = manifest.text
    MANIFEST_TMP_PATH.write_text(manifest)
    with open(tmp_path, 'w') as fout:
        translate_dump_manifest(manifest, fout)
    tmp_path.rename(out_path)

def update_stable_index():
    dir = Path('manifests/stable')
    versions = sorted(
        (file.stem for file in dir.iterdir() if file.stem != 'default' and file.suffix == '.nix'),
        key=parse_version,
    )
    with open(str(dir / 'default.nix'), 'w') as f:
        f.write('{\n')
        for v in versions:
            f.write(f'  {escape_nix_key(v)} = import ./{v}.nix;\n')
        f.write(f'  latest = {escape_nix_string(versions[-1])};\n')
        f.write('}\n')

def sync_stable_channel(*, stop_if_exists, max_fetch=None):
    GITHUB_RELEASES_URL = 'https://api.github.com/repos/rust-lang/rust/releases'
    PER_PAGE = 100

    versions = []
    page = 0
    while True:
        page += 1
        print(f'Fetching release page {page}')
        release_page = retry_with(lambda: requests.get(
            GITHUB_RELEASES_URL,
            params={'per_page': PER_PAGE, 'page': page},
        ))
        release_page.raise_for_status()
        release_page = release_page.json()
        versions.extend(
            tag['tag_name']
            for tag in release_page
            if RE_STABLE_VERSION.match(tag['tag_name'])
            and not version_less(tag['tag_name'], MIN_STABLE_VERSION)
        )
        if len(release_page) < PER_PAGE:
            break
    versions.sort(key=parse_version, reverse=True)

    print(f'Got {len(release_page)} releases to fetch')

    processed = 0
    for version in versions:
        out_path = Path(f'manifests/stable/{version}.nix')
        if out_path.exists():
            if not stop_if_exists:
                continue
            print(f'{version} is already fetched. Stopped')
            break
        fetch_stable_manifest(version, out_path)
        processed += 1
        assert max_fetch is None or processed <= max_fetch, 'Too many versions'
    update_stable_index()

def fetch_nightly_manifest(date: str, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix('.tmp')
    print(f'Fetching nightly {date}')
    manifest = retry_with(lambda: requests.get(f'{DIST_ROOT}/{date}/channel-rust-nightly.toml'))
    if manifest.status_code == 404:
        print(f'Not found, skipped')
        return
    manifest.raise_for_status()
    manifest = manifest.text
    MANIFEST_TMP_PATH.write_text(manifest)
    with open(tmp_path, 'w') as fout:
        translate_dump_manifest(manifest, fout, nightly=True)
    tmp_path.rename(out_path)

def sync_nightly_channel(*, stop_if_exists, max_fetch=None):
    # Fetch the global nightly manifest to retrive the latest nightly version.
    print('Fetching latest nightly version')
    manifest = retry_with(lambda: requests.get(f'{DIST_ROOT}/channel-rust-nightly.toml'))
    manifest.raise_for_status()
    date = datetime.date.fromisoformat(toml.loads(manifest.text)['date'])
    print(f'The latest nightly version is {date}')

    processed = 0
    date += datetime.timedelta(days=1)
    while date > MIN_NIGHTLY_DATE:
        date -= datetime.timedelta(days=1)
        out_path = Path(f'manifests/nightly/{date.year}/{date.isoformat()}.nix')
        if out_path.exists():
            if not stop_if_exists:
                continue
            print(f'{date} is already fetched. Stopped')
            break
        fetch_nightly_manifest(date.isoformat(), out_path)
        processed += 1
        assert max_fetch is None or processed <= max_fetch, 'Too many versions'
    update_nightly_index()

def update_nightly_index():
    dir = Path('manifests/nightly')
    dates = sorted(file.stem for file in dir.rglob('*.nix') if file.stem != 'default')
    with open(str(dir / 'default.nix'), 'w') as f:
        f.write('{\n')
        for date in dates:
            year = date.split('-')[0]
            f.write(f'  {escape_nix_key(date)} = import ./{year}/{date}.nix;\n')
        f.write(f'  latest = {escape_nix_string(dates[-1])};\n')
        f.write('}\n')

def main():
    args = sys.argv[1:]
    if len(args) == 0:
        print('Synchronizing stable channels')
        sync_stable_channel(stop_if_exists=True, max_fetch=SYNC_MAX_FETCH)
        print('Synchronizing nightly channels')
        sync_nightly_channel(stop_if_exists=True, max_fetch=SYNC_MAX_FETCH)
    elif len(args) == 2 and args[0] == 'stable':
        if args[1] == 'all':
            sync_stable_channel(stop_if_exists=False)
        else:
            version = args[1]
            assert RE_STABLE_VERSION.match(version), 'Invalid version'
            fetch_stable_manifest(version, Path(f'manifests/stable/{version}.nix'))
            update_stable_index()
    elif len(args) == 2 and args[0] == 'nightly':
        if args[1] == 'all':
            sync_nightly_channel(stop_if_exists=False)
        else:
            date = datetime.date.fromisoformat(args[1])
            fetch_nightly_manifest(date, Path(f'manifests/nightly/{date.year}/{date.isoformat()}.nix'))
            update_nightly_index()
    else:
        print('''
Usage:
    {0}
        Auto-sync new versions from channels.
    {0} <channel> <version>
        Force to fetch a specific version from a channel.
    {0} <channel> all
        Force to fetch all versions.
'''.format(sys.argv[0]))
        exit(1)

if __name__ == '__main__':
    main()
