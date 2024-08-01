#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: with ps; [ toml requests ])"
from typing import Callable
from fetch import update_nightly_index, update_beta_index
from pathlib import Path
import re
import sys

CHANNELS: list[tuple[Path, Callable[[], None]]] = [
    (Path('manifests/nightly'), update_nightly_index),
    (Path('manifests/beta'), update_beta_index),
]
RE_LATEST_DATE = re.compile('latest = "(.*?)"')

def main():
    args = sys.argv[1:]
    if len(args) != 1:
        print('''
Usage:
    {0} <year>
        Delete all nightly and beta manifests before (excluding) <year>.
''')
        exit(1)

    cut_year = int(args[0])
    for (channel_root, update_index) in CHANNELS:
        for year_dir in channel_root.iterdir():
            if year_dir.is_dir() and int(year_dir.name) < cut_year:
                print(f'deleting {year_dir}')
                for ver in year_dir.iterdir():
                    ver.unlink()
                year_dir.rmdir()
        def latest_ver():
            src = (channel_root / 'default.nix').read_text()
            m = RE_LATEST_DATE.search(src)
            assert m is not None, f'No latest version:\n{src}'
            return m[1]
        before_latest =  latest_ver()
        update_index()
        after_latest =  latest_ver()
        assert before_latest == after_latest, \
            f'Latest version must not be affected: {before_latest} -> {after_latest}'

if __name__ == '__main__':
    main()
