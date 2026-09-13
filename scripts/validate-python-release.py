#!/usr/bin/env python3
"""Reject wheel/index drift and incompatible internal dependencies before upload."""
import argparse
from email.parser import BytesParser
from pathlib import Path
import tomllib
import zipfile

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


def validate(index: Path, wheel_dir: Path) -> None:
    versions = {
        canonicalize_name(p['name']): Version(p['version'])
        for p in tomllib.loads(index.read_text())['packages']
    }
    seen = set()
    errors = []
    for wheel in sorted(wheel_dir.glob('*.whl')):
        with zipfile.ZipFile(wheel) as archive:
            metadata_paths = [n for n in archive.namelist() if n.endswith('.dist-info/METADATA')]
            if len(metadata_paths) != 1:
                raise SystemExit(f'Invalid wheel metadata: {wheel}')
            metadata = BytesParser().parsebytes(archive.read(metadata_paths[0]))
        name = canonicalize_name(metadata['Name'])
        if name not in versions or Version(metadata['Version']) != versions[name]:
            errors.append(f'{wheel.name}: name/version does not match release index')
        seen.add(name)
        # Check internal requirements for every platform and optional capability.
        # An inactive extra today may be enabled by a blueprint tomorrow.
        for raw in metadata.get_all('Requires-Dist', []):
            requirement = Requirement(raw)
            dependency = canonicalize_name(requirement.name)
            if dependency in versions and (requirement.url or versions[dependency] not in requirement.specifier):
                errors.append(f'{name} requires {raw}; release selects {dependency}=={versions[dependency]}')
    errors += [f'Missing indexed wheel: {name}' for name in sorted(versions.keys() - seen)]
    if errors:
        raise SystemExit('Incompatible Python release:\n' + '\n'.join(errors))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('index', type=Path)
    parser.add_argument('wheel_dir', type=Path)
    args = parser.parse_args()
    validate(args.index, args.wheel_dir)
