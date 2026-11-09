import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


class MigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        temp = temporary.name
        self.root = Path(temp)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        for name in ('.gitignore', 'rime.sh', 'managed-files.py', 'validate-backup.py'):
            shutil.copy2(ROOT / name, self.repo)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name, body in {
            'pgrep': 'exit 1',
            'fcitx5': 'exit 1',
            'fcitx5-remote': 'exit 1',
            'rime_deployer': 'mkdir -p "$4"; echo built > "$4/wanxiang.schema.yaml"; '
                             'echo built > "$4/wanxiang.table.bin"',
        }.items():
            exe = bin_dir / name
            exe.write_text(f'#!/bin/sh\n{body}\n')
            exe.chmod(0o700)
        self.env = dict(HOME=temp, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                        XDG_DATA_HOME=f'{temp}/data', XDG_CONFIG_HOME=f'{temp}/config',
                        XDG_STATE_HOME=f'{temp}/state', GIT_CONFIG_NOSYSTEM='1')
        self.rime = self.root / 'data/fcitx5/rime'
        self.rime.mkdir(parents=True)
        (self.rime / 'wanxiang.schema.yaml').write_text('schema')
        (self.rime / 'wanxiang.custom.yaml').write_text('custom')
        self.learned = self.rime / 'wanxiang.userdb/CURRENT'
        self.learned.parent.mkdir()
        self.learned.write_text('learned')
        self.prefs = self.root / 'config/fcitx5/conf/notifications.conf'
        self.prefs.parent.mkdir(parents=True)
        self.prefs.write_text('preferences')

    def command(self, *args, check=True):
        return subprocess.run(args, cwd=self.repo, env=self.env, check=check,
                              text=True, capture_output=True)

    def test_capture_excludes_machine_state(self):
        self.command('git', 'init', '-q')
        nested = self.rime / 'lua'
        nested.mkdir()
        (nested / '.gitignore').write_text('*\n')
        (nested / 'filter.lua').write_text('return {}')
        self.command('./rime.sh', 'capture')
        names = set(self.command('git', 'ls-files').stdout.splitlines())
        self.assertIn('files/rime/lua/filter.lua', names)
        self.assertIn('files/rime/wanxiang.custom.yaml', names)
        self.assertIn('files/fcitx5-config/conf/notifications.conf', names)
        self.assertNotIn('files/rime/lua/.gitignore', names)
        self.assertFalse((self.repo / 'files/rime/wanxiang.userdb').exists())

    def test_portable_snapshot_cannot_replace_personal_data(self):
        portable = self.root / 'portable'
        target = self.root / 'data'
        directory = target / 'data/rime/filter.lua'
        directory.mkdir(parents=True)
        personal = directory / 'filter.lua'
        personal.write_text('unmanaged')
        (portable / 'rime').mkdir(parents=True)
        (portable / 'rime/filter.lua').write_text('managed')
        result = self.command('python3', 'managed-files.py', 'apply', portable,
                              self.root / 'manifest', target, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(personal.read_text(), 'unmanaged')

        learned = portable / 'rime/wanxiang.userdb/CURRENT'
        learned.parent.mkdir()
        learned.write_text('foreign database')
        result = self.command('python3', 'managed-files.py', 'check', portable, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Personal database in portable snapshot', result.stderr)

    def test_restore_replaces_live_data_but_preserves_identity(self):
        identity = self.rime / 'installation.yaml'
        identity.write_text('source identity')
        timestamp = 1_700_000_000
        os.utime(self.learned, (timestamp, timestamp))
        self.command('./rime.sh', 'backup')
        archive, = (self.root / 'state/rime-config/backups').glob('*.tar.zst')
        self.learned.write_text('changed')
        os.utime(self.learned, (timestamp, timestamp))
        self.prefs.write_text('changed')
        identity.write_text('destination identity')
        introduced = self.rime / 'introduced.yaml'
        introduced.touch()
        self.command('./rime.sh', 'restore', archive)
        self.assertEqual(self.learned.read_text(), 'learned')
        self.assertEqual(self.prefs.read_text(), 'preferences')
        self.assertEqual(identity.read_text(), 'destination identity')
        self.assertFalse(introduced.exists())

    def test_validator_rejects_escaping_and_link_entries(self):
        for name, kind in (('data/../../escape', tarfile.REGTYPE),
                           ('data/link', tarfile.SYMTYPE), ('config/link', tarfile.LNKTYPE)):
            with self.subTest(name=name):
                tar_path = self.root / 'unsafe.tar'
                archive = self.root / 'unsafe.tar.zst'
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.linkname = '/tmp/outside'
                with tarfile.open(tar_path, 'w') as tar:
                    tar.addfile(entry)
                self.command('zstd', '-qf', tar_path, '-o', archive)
                result = self.command('python3', 'validate-backup.py', archive, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unsafe archive entry', result.stderr)

    def test_restore_rejects_archive_without_two_zero_blocks(self):
        tar_path = self.root / 'incomplete.tar'
        archive = self.root / 'incomplete.tar.zst'
        with tarfile.open(tar_path, 'w') as tar:
            for name in ('data', 'data/rime', 'config'):
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.DIRTYPE
                tar.addfile(entry)
        full_tar = tar_path.read_bytes()
        for zero_blocks in (0, 1):
            with self.subTest(zero_blocks=zero_blocks):
                tar_path.write_bytes(full_tar[:(3 + zero_blocks) * tarfile.BLOCKSIZE])
                self.command('zstd', '-qf', tar_path, '-o', archive)
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                archive.with_suffix('.zst.sha256').write_text(f'{digest}  {archive.name}\n')
                result = self.command('./rime.sh', 'restore', archive, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Incomplete tar end marker', result.stderr)
                self.assertEqual(self.prefs.read_text(), 'preferences')
