# The install script for rust components.
# Some toolchains have tons of install directives which makes bash script too slow.
import os
from pathlib import Path
from shutil import copy, copytree

out = Path(os.environ['out'])
verbose = os.environ.get('VERBOSE_INSTALL') == '1'

installer_version = int(Path('./rust-installer-version').read_text().strip())
if installer_version == 3:
    for component in Path('./components').read_text().splitlines():
        print(f'Installing component {component}')
        for directive in (Path(component) / 'manifest.in').read_text().splitlines():
            cmd, file = directive.split(':')
            in_file, out_file = Path(component) / file, out / file
            out_file.parent.mkdir(parents=True, exist_ok=True)
            if verbose:
                print(f'Installing {cmd}: {file}')
            if cmd == 'file':
                copy(in_file, out_file)
            elif cmd == 'dir':
                copytree(in_file, out_file)
            else:
                assert False, f'Unknown command: {cmd}'
else:
    assert False, f'Unknown installer version: {installer_version}'
