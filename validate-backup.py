#!/usr/bin/env python3
"""Reject traversal, links and special files before restoring a local backup."""
import subprocess
import sys
import tarfile
from pathlib import PurePosixPath


class CompleteTarInfo(tarfile.TarInfo):
    @classmethod
    def fromtarfile(cls, archive):
        try:
            return super().fromtarfile(archive)
        except tarfile.EOFHeaderError:
            # TarFile.next() otherwise treats both missing headers and zero blocks as EOF.
            archive.has_end_marker = archive.fileobj.read(tarfile.BLOCKSIZE) == bytes(tarfile.BLOCKSIZE)
            raise


def validate(path):
    process = subprocess.Popen(["zstd", "-dc", "--", path], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|", tarinfo=CompleteTarInfo) as archive:
            for member in archive:
                name = PurePosixPath(member.name)
                if (name.is_absolute() or ".." in name.parts or not name.parts
                        or name.parts[0] not in {"data", "config"}
                        or not (member.isfile() or member.isdir())):
                    raise ValueError(f"Unsafe archive entry: {member.name!r}")
            if not getattr(archive, "has_end_marker", False):
                raise ValueError("Incomplete tar end marker")
        while process.stdout.read(1024 * 1024):
            pass
    except BaseException:
        process.terminate()
        process.wait()
        raise
    finally:
        process.stdout.close()
    status = process.wait()
    if status:
        raise ValueError(f"zstd failed: {status}")

if __name__ == "__main__":
    validate(sys.argv[1])
