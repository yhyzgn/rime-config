# Portable Wanxiang Rime / Fcitx5

Linux configuration snapshot, install, full backup/restore and explicit Git sync. Personal dictionaries and custom text can contain private information: keep the remote **private**. Nothing uploads automatically.

To publish the initial snapshot, review the committed `files/` tree first. If no remote is configured, `gh repo create rime-config --private --source=. --remote=origin --push` creates a private GitHub repository and uploads it. Skip this step if you want to keep the snapshot local.

## New machine

```sh
git clone <your-private-repository-url> rime-config
cd rime-config
./rime.sh deps
./rime.sh install
```

Install verifies the language model, stops an existing Fcitx5 process, makes a full backup, assembles and builds a staged configuration, then applies it. A failed deployment rolls back the live files, managed-file manifest and sync baseline. Fcitx5 is restarted only if it was running. On a fresh desktop, select Fcitx5 in desktop input-method settings, log out/in, then add Rime in `fcitx5-configtool`. Wayland/desktop integration is not changed by this script.

Portable files include Rime schemas, dictionaries, Lua, `*.custom.yaml`, Fcitx5 preferences and themes. Git excludes generated build/sync/user databases, the model, installation identity, runtime Lua statistics and generated keyboard-layout catalogs. Notification preferences are included. Previously installed portable files removed from Git are removed on the next install; unrelated files and personal databases are retained. Unknown files from before this tool's first install are deliberately not deleted.

Install rejects unreadable snapshots, snapshots containing Rime user databases, and managed file paths that collide with destination directories.

## Capture and publish

```sh
./rime.sh capture                 # snapshots and stages live portable settings
git diff --cached --stat          # review before committing
git commit -m 'chore: update Rime settings'
# Once per clone, after checking that this destination is private:
git config rime.approvedPushURL "$(git remote get-url --push origin)"
./rime.sh sync push               # capture, commit changes, push current branch
```

`sync push` requires a clean checkout, one explicitly approved push URL and a live/repository baseline from a previous capture/install. It fetches and refuses a behind/diverged branch before changing the snapshot. After pulling another machine's changes, **install before pushing**; explicit `capture` instead means intentionally choosing the current machine's live settings.

```sh
./rime.sh sync pull               # fast-forward repository only
./rime.sh install                 # backup and apply the pulled snapshot
```

No cron jobs or background sync. Run these commands explicitly; do not run migration commands concurrently or edit settings while they run.

## Complete backup and restore

```sh
./rime.sh backup
./rime.sh restore /path/to/full-YYYYMMDD-HHMMSS-ID.tar.zst
```

Backups live in `${XDG_STATE_HOME:-~/.local/state}/rime-config/backups`. Copy **both** the `.tar.zst` archive and `.sha256` file off-machine. They include the complete Fcitx5 data/config trees, personal learning databases and language model; they are not put in Git. Restore verifies the checksum and tar end marker and rejects traversal, links and special archive entries. It then backs up the destination, replaces its full trees, preserves its installation identity and rebuilds Rime. Full restore intentionally removes destination files not in the archive. Archives are private but **not encrypted**. Checksums detect corruption, not malicious replacement; restore only trusted backups. Backups containing symlinks/special files are rejected rather than claiming they are portable.

## Model availability

The model SHA-256 is pinned in `rime.sh`. The cache is keyed by that digest; a matching installed model seeds it automatically. The upstream `LTS` URL is mutable: if its bytes change, install fails closed. Keep a full backup, or preserve this file externally:

```text
~/.cache/rime-config/<MODEL_SHA>/wanxiang-lts-zh-hans.gram
```

A fresh machine can use that exact cache file without downloading. A pinned hash does not guarantee upstream retention. Upgrade the URL and hash together only after reviewing the new model.

## Checks

```sh
python3 -m unittest -v test_migration.py
```

Tests use temporary directories and fake service/deployer commands; they never stop the desktop input method. They exercise actual filesystem/archive/Git behavior, not desktop integration. Supported dependency recipes: Fedora and Debian/Ubuntu; no macOS or Windows installer.
