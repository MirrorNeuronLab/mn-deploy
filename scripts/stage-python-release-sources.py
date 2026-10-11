#!/usr/bin/env python3
"""Stage Python build sources without mutating release checkouts."""
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def stage_sources(rows_file: Path, build_root: Path) -> None:
    if not hasattr(tarfile, 'data_filter'):
        raise SystemExit('Python publishing requires a current Python 3.11+ with tarfile.data_filter.')
    repositories = {}
    rows = []
    for line in rows_file.read_text().splitlines():
        name, raw_path, formats, version = line.split('\t')
        package = Path(raw_path).resolve()
        result = subprocess.run(['git', '-C', str(package), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
        if result.returncode == 0:
            repo = Path(result.stdout.strip()).resolve()
            if repo not in repositories:
                if subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip():
                    raise SystemExit(f'Uncommitted source changes in {repo}; commit or preserve them before publishing.')
                target = build_root / f'repo-{len(repositories)}' / repo.name
                target.mkdir(parents=True)
                with subprocess.Popen(['git', '-C', str(repo), 'archive', 'HEAD'], stdout=subprocess.PIPE) as archive:
                    with tarfile.open(fileobj=archive.stdout, mode='r|') as source:
                        source.extractall(target, filter='data')
                    if archive.wait():
                        raise SystemExit(f'Could not archive release source: {repo}')
                repositories[repo] = target
            staged = repositories[repo] / package.relative_to(repo)
        else:
            if any((parent / '.git').exists() for parent in (package, *package.parents)):
                raise SystemExit(f'Could not read Git release source: {package}')
            # A custom index may select a standalone source project without Git.
            staged = build_root / f'project-{len(rows)}' / package.name
            staged.parent.mkdir(parents=True)
            shutil.copytree(package, staged, ignore=shutil.ignore_patterns(
                '.git', '.venv*', '__pycache__', 'build', 'dist', '*.egg-info',
            ))
        rows.append('\t'.join((name, str(staged), formats, version)))
    rows_file.write_text('\n'.join(rows) + '\n')


if __name__ == '__main__':
    stage_sources(Path(sys.argv[1]), Path(sys.argv[2]))
