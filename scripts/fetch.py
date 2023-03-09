#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: with ps; [ toml requests typing-extensions ])"
from datetime import date
from pathlib import Path
from typing import Any, TextIO
from typing_extensions import Self
import base64
import re
import sys
import time

import requests
import toml

MAX_TRIES = 3
RETRY_DELAY = 3.0

MIN_DATE = date.fromisoformat('2018-09-13') # 1.29.0

DIST_ROOT = 'https://static.rust-lang.org/dist'

NIX_KEYWORDS = {'', 'if', 'then', 'else', 'assert', 'with', 'let', 'in', 'rec', 'inherit', 'or'}
MANIFEST_TMP_PATH = Path('/tmp/manifest.toml') # For debug.
MANIFESTS_DIR = Path('manifests')

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

class RustVersion:
    channel: str
    version: str

    def __init__(self, version: str) -> None:
        self.version = version

    def __str__(self) -> str:
        return f'{self.channel}-{self.version}'

    def manifest_url(self) -> str:
        raise NotImplementedError()

    @classmethod
    def manifest_dir(cls) -> Path:
        return MANIFESTS_DIR / cls.channel

    def manifest_path(self) -> Path:
        raise NotImplementedError()

class RustStable(RustVersion):
    # Only accept 3-parts versions here. See also `ManifestIndex.RE_LINE`.
    RE_STABLE_VERSION = re.compile(r'^(\d+)\.(\d+)\.(\d+)$')
    channel = 'stable'
    dat: date | None

    def __init__(self, version: str, dat: date | None = None) -> None:
        m = self.RE_STABLE_VERSION.match(version)
        assert m is not None, f'Invalid stable version: {version}'
        super().__init__(version)
        self.dat = dat

    def manifest_url(self) -> str:
        return f'{DIST_ROOT}/channel-rust-{self.version}.toml'

    def manifest_path(self) -> Path:
        return self.manifest_dir() / f'{self.version}.nix'

class RustNightly(RustVersion):
    channel = 'nightly'
    dat: date

    def __init__(self, dat: date) -> None:
        super().__init__(dat.isoformat())
        self.dat = dat

    def manifest_url(self) -> str:
        return f'{DIST_ROOT}/{self.version}/channel-rust-{self.channel}.toml'

    def manifest_path(self) -> Path:
        return self.manifest_dir() / str(self.dat.year) / f'{self.version}.nix'

class RustBeta(RustNightly):
    channel = 'beta'

# https://github.com/rust-lang/generate-manifest-list
class ManifestIndex:
    DIST_INDEX_URL = 'https://static.rust-lang.org/manifests.txt'
    # NB. Only match 3-parts version like `1.67.0`, which only appears once (except 1.8.0).
    # 2-parts version like `1.67` appears every time a new patch release is out.
    RE_LINE = re.compile(r'/dist/([0-9]{4}-[0-9]{2}-[0-9]{2})/channel-rust-(beta|nightly|[0-9]+\.[0-9]+\.[0-9]+).toml$', re.M)

    stable: list[RustStable]
    nightly: list[RustNightly]
    beta: list[RustBeta]

    def __init__(self, content: str) -> None:
        self.stable, self.beta, self.nightly = [], [], []
        for m in self.RE_LINE.finditer(content):
            dat = date.fromisoformat(m[1])
            version = m[2]
            match version:
                case 'beta':
                    self.beta.append(RustBeta(dat))
                case 'nightly':
                    self.nightly.append(RustNightly(dat))
                case _:
                    self.stable.append(RustStable(version, dat))

    @classmethod
    def fetch(cls) -> Self:
        print('Fetching manifest index')
        index = fetch_url(cls.DIST_INDEX_URL).text
        return cls(index)

TARGETS_PATH = MANIFESTS_DIR / 'targets.nix'
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

RENAMES_PATH = MANIFESTS_DIR / 'renames.nix'
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

PROFILES_PATH = MANIFESTS_DIR / 'profiles.nix'
profiles_map = dict((line.strip(), i) for i, line in enumerate(PROFILES_PATH.read_text().strip().split('\n')[1:-1]))
def compress_profiles(profiles: dict) -> int:
    serialized = '{ ' + ''.join(
        escape_nix_key(k) + ' = [ ' + ''.join(escape_nix_string(comp) + ' ' for comp in v) + ']; '
        for k, v in sorted(profiles.items())
    ) + '}'

    if serialized in profiles_map:
        return profiles_map[serialized]
    idx = len(profiles_map)
    profiles_map[serialized] = idx

    with open(str(PROFILES_PATH), 'w') as f:
        f.write('[\n')
        for _, ser in sorted((idx, ser) for ser, idx in profiles_map.items()):
            f.write('  ' + ser + '\n')
        f.write(']\n')
    return idx

def fetch_url(url: str, params=None, headers={}) -> requests.Response:
    i = 0
    while True:
        try:
            resp = requests.get(url, params=params, headers=headers)
            resp.raise_for_status()
            return resp
        except requests.exceptions.RequestException as e:
            i += 1
            if i >= MAX_TRIES:
                raise
            print(e)
            time.sleep(RETRY_DELAY)

def translate_dump_manifest(channel: str, manifest_content: str, f: TextIO):
    manifest: dict[str, Any] = toml.loads(manifest_content)
    dat = manifest['date']
    rustc_version = manifest['pkg']['rustc']['version'].split()[0]
    renames_idx = compress_renames(manifest['renames'])
    strip_tail = '-preview'

    default_url_version = rustc_version if channel == 'stable' else channel

    f.write('{')
    f.write(f'v={escape_nix_string(rustc_version)};')
    f.write(f'd={escape_nix_string(dat)};')
    f.write(f'r={renames_idx};')
    if 'profiles' in manifest:
        f.write(f'p={compress_profiles(manifest["profiles"])};')

    for pkg_name in sorted(manifest['pkg'].keys()):
        pkg = manifest['pkg'][pkg_name]
        pkg_name_stripped = pkg_name[:-len(strip_tail)] if pkg_name.endswith(strip_tail) else pkg_name
        pkg_targets = sorted(pkg['target'].keys())

        url_version = rustc_version
        url_target_map = {}
        for target_name in pkg_targets:
            target = pkg['target'][target_name]
            if not target['available']:
                continue
            url = target['xz_url']
            target_tail = '' if target_name == '*' else '-' + target_name
            start = f'{DIST_ROOT}/{dat}/{pkg_name_stripped}-'
            end = f'{target_tail}.tar.xz'

            # Occurs in nightly-2019-01-10. Maybe broken or hirarerchy change?
            if url.startswith('nightly/'):
                url = DIST_ROOT + url[7:]

            # The target part may not be the same as current one.
            # This occurs in `pkg.rust-std.target.aarch64-apple-darwin` of nightly-2022-02-02,
            # which points to the URL of x86_64-apple-darwin rust-docs.
            if not url.endswith(end):
                assert url.startswith(start + default_url_version + '-') and url.endswith('.tar.xz')
                url_target = url[len(start + default_url_version + '-'):-len('.tar.xz')]
                assert url_target in pkg_targets
                url_target_map[target_name] = url_target
                continue

            assert url.startswith(start) and url.endswith(end), f'Unexpected url: {url}'
            url_version = url[len(start):-len(end)]

        f.write(f'{pkg_name}={{')
        if url_version != default_url_version:
            f.write(f'u={escape_nix_string(url_version)};')
        for target_name in pkg_targets:
            # Forward to another URL.
            if target_name in url_target_map:
                url_target = url_target_map[target_name]
                assert pkg['target'][url_target] == pkg['target'][target_name]
                url_target_id = compress_target(url_target)[1:]
                assert url_target_id
                f.write(f'{compress_target(target_name)}={url_target_id};')
                continue

            target = pkg['target'][target_name]
            if not target['available']:
                continue
            url = target['xz_url']
            # See above.
            if url.startswith('nightly/'):
                url = DIST_ROOT + url[7:]
            hash = to_base64(target['xz_hash']) # Hash must not contains quotes.
            target_tail = '' if target_name == '*' else '-' + target_name
            expect_url = f'https://static.rust-lang.org/dist/{dat}/{pkg_name_stripped}-{url_version}{target_tail}.tar.xz'
            assert url == expect_url, f'Unexpected url: {url}, expecting: {expect_url}'
            f.write(f'{compress_target(target_name)}="{hash}";')

        f.write('};')
    f.write('}\n')

# Fetch, translate and save a manifest file.
def update_manifest(version: RustVersion):
    out_path = version.manifest_path()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix('.tmp')
    print(f'Fetching {version}')
    manifest = fetch_url(version.manifest_url()).text
    MANIFEST_TMP_PATH.write_text(manifest)
    with open(tmp_path, 'w') as fout:
        translate_dump_manifest(version.channel, manifest, fout)
    tmp_path.rename(out_path)

def update_stable_index():
    dir = RustStable.manifest_dir()

    def parse_version(ver: str) -> tuple:
        return tuple(map(int, ver.split('.')))

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

def update_beta_index():
    update_nightly_index(dir=RustBeta.manifest_dir())

def update_nightly_index(*, dir=RustNightly.manifest_dir()):
    dates = sorted(file.stem for file in dir.rglob('*.nix') if file.stem != 'default')
    with open(str(dir / 'default.nix'), 'w') as f:
        f.write('{\n')
        for date in dates:
            year = date.split('-')[0]
            f.write(f'  {escape_nix_key(date)} = import ./{year}/{date}.nix;\n')
        f.write(f'  latest = {escape_nix_string(dates[-1])};\n')
        f.write('}\n')

def main():
    match sys.argv[1:]:
        case []:
            index = ManifestIndex.fetch()

            pending = []
            for version in index.stable + index.beta + index.nightly:
                assert version.dat is not None
                if version.dat >= MIN_DATE and not version.manifest_path().exists():
                    pending.append(version)

            if not pending:
                print('Up to date')
                return
            print(f'Pending {len(pending)} updates: {", ".join(str(v) for v in pending)}')

            for version in pending:
                update_manifest(version)
            update_stable_index()
            update_beta_index()
            update_nightly_index()
        case ['stable', version]:
            update_manifest(RustStable(version))
            update_stable_index()
        case ['beta', date_str]:
            update_manifest(RustBeta(date.fromisoformat(date_str)))
            update_beta_index()
        case ['nightly', date_str]:
            update_manifest(RustNightly(date.fromisoformat(date_str)))
            update_nightly_index()
        case _:
            arg0 = sys.argv[0]
            print(f'''
Usage:
    {arg0} <channel>
        Synchronize all new stable, beta and nightly versions.
    {arg0} <channel> <version>
        Fetch a specific channel and version.
''')
            exit(1)

if __name__ == '__main__':
    main()
