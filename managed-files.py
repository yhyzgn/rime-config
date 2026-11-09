#!/usr/bin/env python3
"""Validate portable files and remove only obsolete, previously managed paths."""
import json
import shutil
import stat
import sys
from pathlib import Path, PurePosixPath


def is_user_database(path):
    return path.parts[:1] == ('rime',) and any('.userdb' in part for part in path.parts[1:])


def scan(root):
    result = []
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f'Expected a real directory: {root}')
    directories = [root]
    while directories:
        for path in directories.pop().iterdir():
            relative = path.relative_to(root)
            if is_user_database(relative):
                raise ValueError(f'Personal database in portable snapshot: {path}')
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                directories.append(path)
            elif not stat.S_ISREG(info.st_mode):
                raise ValueError(f'Unsupported portable entry: {path}')
            elif info.st_size > 90 * 1024 * 1024:
                raise ValueError(f'Portable file exceeds 90 MiB: {path}')
            else:
                result.append(relative.as_posix())
    return sorted(result)


def destination(name, target):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or len(path.parts) < 2:
        raise ValueError(f'Unsafe managed path: {name!r}')
    roots = {'rime': target / 'data/rime', 'themes': target / 'data/themes',
             'fcitx5-config': target / 'config'}
    root = roots[path.parts[0]]
    result = root.joinpath(*path.parts[1:])
    if not result.is_relative_to(target):
        raise ValueError(f'Path escapes staged target: {name!r}')
    for parent in (result, *result.parents):
        if parent == target:
            break
        if parent.is_symlink():
            raise ValueError(f'Symlink intersects managed path: {parent}')
    return result


def apply(source, manifest, target):
    names = scan(source)
    previous = json.loads(manifest.read_text()) if manifest.exists() else []
    for name in set(previous) - set(names):
        if is_user_database(PurePosixPath(name)):
            continue
        path = destination(name, target)
        if path.is_file():
            path.unlink()
    for name in names:
        path = destination(name, target)
        if path.is_dir():
            raise ValueError(f'Portable file collides with a directory: {path}')
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, path)
    (target.parent / 'next-manifest.json').write_text(json.dumps(names))


if __name__ == '__main__':
    if sys.argv[1] == 'check':
        scan(Path(sys.argv[2]))
    elif sys.argv[1] == 'apply':
        apply(*(Path(arg) for arg in sys.argv[2:]))
    else:
        raise ValueError('Expected check or apply')
