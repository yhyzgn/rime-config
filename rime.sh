#!/usr/bin/env bash
set -euo pipefail
umask 077
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/rime-config
BACKUPS=$STATE/backups
MODEL=wanxiang-lts-zh-hans.gram
MODEL_URL=https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram
MODEL_SHA=769854c83f6c914a05a1e1abb67c31c00f1ae622a41878e05957bcdee3dbda9a
EXCLUDES=(--exclude=.git --exclude=.gitignore --exclude=/build/ --exclude=/sync/ --exclude='*.userdb*' --exclude='*.gram' --exclude=/installation.yaml --exclude=/user.yaml --exclude=/AGENTS.md --exclude=/plum/ --exclude=/tools/ --exclude=/others/ --exclude='*.log' --exclude=/lua/sequence/ --exclude=/lua/stats/)
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "Missing command: $1"; }
git_repo() { git -C "$REPO" "$@"; }
restart=0
rollback=0
work=
cleanup() {
    local status=$?
    trap - EXIT
    if ((rollback)); then
        printf 'Deployment failed; restoring previous files.\n' >&2
        if ! rsync -a --checksum --delete "$work/before/data/" "$DATA/" || ! rsync -a --checksum --delete "$work/before/config/" "$CONFIG/"; then
            printf 'ROLLBACK FAILED. Keep Fcitx5 stopped; recover from %s and %s\n' "$work" "$LAST_BACKUP" >&2
            exit 1
        fi
        local file
        for file in managed.json baseline; do
            if [[ -f $work/before/$file ]]; then cp -- "$work/before/$file" "$STATE/$file"
            else rm -f -- "$STATE/$file"; fi || {
                printf 'ROLLBACK FAILED restoring %s. Recover state from %s\n' "$file" "$work" >&2
                exit 1
            }
        done
    fi
    [[ -z $work ]] || rm -rf -- "$work"
    if ((restart)) && ! pgrep -u "$(id -u)" -x fcitx5 >/dev/null; then
        # shortcut: KDE Wayland 上浏览器经 kwin 的 zwp_input_method 特权连接输入,只有 kwin 拉起的 fcitx5 才有该连接;手动 fcitx5 -d 或手动 launcher 都不行,需 --replace 重启 kwin 让它重新拉起
        if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v kwin_wayland_wrapper >/dev/null; then
            setsid kwin_wayland_wrapper --replace >/dev/null 2>&1 < /dev/null &
            local i
            for ((i = 0; i < 15; i++)); do
                pgrep -u "$(id -u)" -x fcitx5 >/dev/null && break
                sleep 1
            done
        else
            fcitx5 -d || status=1
            sleep 1
        fi
        pgrep -u "$(id -u)" -x fcitx5 >/dev/null || status=1
    fi
    exit "$status"
}
trap cleanup EXIT
pause() {
    need fcitx5-remote
    if pgrep -u "$(id -u)" -x fcitx5 >/dev/null; then
        restart=1
        fcitx5-remote -e
        for ((i=0; i<50; i++)); do
            if ! pgrep -u "$(id -u)" -x fcitx5 >/dev/null; then return; fi
            sleep 0.1
        done
        fail 'Fcitx5 did not exit; no data was copied.'
    fi
}
backup() {
    local temp archive
    need tar; need zstd; need rsync
    [[ -d $DATA || -d $CONFIG ]] || fail 'No Fcitx5 data/configuration exists.'
    mkdir -p "$BACKUPS"
    temp=$(mktemp -d "$BACKUPS/.backup.XXXXXX")
    mkdir -p "$temp/data" "$temp/config"
    [[ ! -d $DATA ]] || rsync -a "$DATA/" "$temp/data/"
    [[ ! -d $CONFIG ]] || rsync -a "$CONFIG/" "$temp/config/"
    tar --zstd -cpf "$temp/full.tar.zst" -C "$temp" data config
    python3 "$REPO/validate-backup.py" "$temp/full.tar.zst"
    archive=$BACKUPS/full-$(date +%Y%m%d-%H%M%S)-${temp##*.}.tar.zst
    mv -- "$temp/full.tar.zst" "$archive"
    (cd "$BACKUPS" && sha256sum "${archive##*/}" > "${archive##*/}.sha256" && sha256sum -c "${archive##*/}.sha256")
    rm -rf -- "$temp"
    LAST_BACKUP=$archive
    printf 'Verified backup: %s\n' "$archive"
}
portable_tree() { git_repo rev-parse HEAD:files; }
record_baseline() {
    mkdir -p "$STATE"
    # The content hash changes even before a snapshot is committed.
    git_repo add -- files
    local tree
    tree=$(git_repo write-tree)
    git_repo rev-parse "$tree:files" > "$STATE/baseline"
}
capture() {
    need rsync
    [[ -f $DATA/rime/wanxiang.schema.yaml ]] || fail 'Wanxiang is not installed.'
    local temp
    temp=$(mktemp -d "$REPO/.capture.XXXXXX")
    mkdir -p "$temp/rime" "$temp/fcitx5-config" "$temp/themes"
    rsync -a "${EXCLUDES[@]}" "$DATA/rime/" "$temp/rime/"
    [[ ! -d $CONFIG ]] || rsync -a --exclude=.git --exclude=.gitignore --exclude=/conf/cached_layouts "$CONFIG/" "$temp/fcitx5-config/"
    [[ ! -d $DATA/themes ]] || rsync -a --exclude=.git --exclude=.gitignore "$DATA/themes/" "$temp/themes/"
    python3 "$REPO/managed-files.py" check "$temp"
    [[ -f $temp/rime/wanxiang.custom.yaml ]] || fail 'Required custom patch is missing.'
    mkdir -p "$REPO/files"
    rsync -a --checksum --delete "$temp/" "$REPO/files/"
    rm -rf -- "$temp"
    record_baseline
    printf 'Captured configuration (including personal text); review staged files before publishing.\n'
}
model() {
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/rime-config/$MODEL_SHA tmp
    mkdir -p "$cache"
    if [[ ! -f $cache/$MODEL ]] || ! printf '%s  %s\n' "$MODEL_SHA" "$cache/$MODEL" | sha256sum -c --status; then
        tmp=$(mktemp "$cache/model.XXXXXX")
        if [[ -f $DATA/rime/$MODEL ]] && printf '%s  %s\n' "$MODEL_SHA" "$DATA/rime/$MODEL" | sha256sum -c --status; then
            cp -- "$DATA/rime/$MODEL" "$tmp"
        else
            curl --fail --location --retry 3 --output "$tmp" "$MODEL_URL"
        fi
        printf '%s  %s\n' "$MODEL_SHA" "$tmp" | sha256sum -c --status || fail 'Pinned model unavailable/changed; supply the original bytes in the digest cache. Do not automatically update the hash.'
        mv -- "$tmp" "$cache/$MODEL"
    fi
    install -m 600 "$cache/$MODEL" "$work/next/data/rime/$MODEL"
    printf '%s  %s\n' "$MODEL_SHA" "$work/next/data/rime/$MODEL" | sha256sum -c --status
}
prepare_target() {
    need rsync; need rime_deployer; need fcitx5
    pause
    if [[ -d $DATA || -d $CONFIG ]]; then backup; fi
    mkdir -p "$work/before/data" "$work/before/config" "$work/next/data" "$work/next/config"
    [[ ! -d $DATA ]] || rsync -a "$DATA/" "$work/before/data/"
    [[ ! -d $CONFIG ]] || rsync -a "$CONFIG/" "$work/before/config/"
    rsync -a "$work/before/" "$work/next/"
    local file
    for file in managed.json baseline; do
        [[ ! -f $STATE/$file ]] || cp -- "$STATE/$file" "$work/before/$file"
    done
}
apply_target() {
    rm -rf -- "$work/next/data/rime/build"
    rime_deployer --build "$work/next/data/rime" /usr/share/rime-data "$work/next/data/rime/build"
    # rime_deployer can return success without producing the requested schema.
    [[ -s $work/next/data/rime/build/wanxiang.schema.yaml && -s $work/next/data/rime/build/wanxiang.table.bin ]] || fail 'Wanxiang build is incomplete; live configuration was not changed.'
    mkdir -p "$DATA" "$CONFIG"
    rollback=1
    # Tar timestamps can round to seconds; equal size and mtime do not imply equal content.
    rsync -a --checksum --delete "$work/next/data/" "$DATA/"
    rsync -a --checksum --delete "$work/next/config/" "$CONFIG/"
}
install_config() {
    [[ -f $REPO/files/rime/wanxiang.custom.yaml ]] || fail 'No captured configuration.'
    python3 "$REPO/managed-files.py" check "$REPO/files"
    work=$(mktemp -d)
    # Download and verify before stopping the input method.
    mkdir -p "$work/next/data/rime"
    model
    mv -- "$work/next/data/rime/$MODEL" "$work/model"
    prepare_target
    python3 "$REPO/managed-files.py" apply "$REPO/files" "$STATE/managed.json" "$work/next"
    install -m 600 "$work/model" "$work/next/data/rime/$MODEL"
    apply_target
    mkdir -p "$STATE"
    cp -- "$work/next-manifest.json" "$STATE/managed.json"
    record_baseline
    rollback=0
    printf 'Configuration deployed; preserving personal dictionaries and unmanaged files.\n'
}
restore_backup() {
    local archive=${2:-} expected actual
    [[ -f $archive && -f $archive.sha256 ]] || fail 'Provide an archive and its .sha256 sidecar.'
    archive=$(realpath "$archive")
    read -r expected _ < "$archive.sha256"
    actual=$(sha256sum "$archive"); actual=${actual%% *}
    [[ $expected =~ ^[0-9a-f]{64}$ && $actual == "$expected" ]] || fail 'Backup checksum mismatch.'
    python3 "$REPO/validate-backup.py" "$archive"
    work=$(mktemp -d)
    prepare_target
    rm -rf -- "$work/next"
    mkdir -p "$work/next"
    tar --zstd --no-same-owner -xf "$archive" -C "$work/next"
    [[ -d $work/next/data/rime && -d $work/next/config ]] || fail 'Not a complete Rime backup.'
    # Keep the destination installation identity when moving between machines.
    rm -f -- "$work/next/data/rime/installation.yaml"
    if [[ -f $work/before/data/rime/installation.yaml ]]; then cp -- "$work/before/data/rime/installation.yaml" "$work/next/data/rime/"; fi
    apply_target
    rm -f -- "$STATE/managed.json" "$STATE/baseline"
    rollback=0
    printf 'Full backup restored and rebuilt. Run capture before the next push.\n'
}
clean_checkout() {
    local status
    status=$(git_repo status --porcelain)
    [[ -z $status ]] || fail 'Commit or resolve local repository changes first.'
}
case ${1:-help} in
capture) pause; capture ;;
backup) pause; backup ;;
install) install_config ;;
restore) restore_backup "$@" ;;
deps)
    if command -v dnf >/dev/null; then
        sudo dnf install -y git rsync curl zstd python3 fcitx5 fcitx5-rime librime-lua librime-octagram librime-tools
    elif command -v apt-get >/dev/null; then
        sudo apt-get update
        sudo apt-get install -y git rsync curl zstd python3 fcitx5 fcitx5-rime librime-bin librime-plugin-lua librime-plugin-octagram
    else fail 'Automatic dependencies support Fedora/Debian/Ubuntu only.'; fi
    ;;
sync)
    clean_checkout
    case ${2:-} in
    push)
        url=$(git_repo remote get-url --push --all origin)
        [[ $url != *$'\n'* ]] || fail 'Multiple push destinations are not supported.'
        approved=$(git_repo config --get rime.approvedPushURL || true)
        [[ $url == "$approved" ]] || fail "Review remote privacy and approve its exact push URL: git config rime.approvedPushURL '$url'"
        branch=$(git_repo symbolic-ref --short HEAD)
        git_repo fetch origin
        if git_repo show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git_repo merge-base --is-ancestor "origin/$branch" HEAD || fail 'Remote is ahead/diverged; pull and install before pushing.'
        fi
        [[ -f $STATE/baseline && $(cat "$STATE/baseline") == "$(portable_tree)" ]] || fail 'Repository snapshot is not the last applied/captured version; install first, or explicitly capture reviewed live settings.'
        pause
        capture
        git_repo ls-files --error-unmatch files/rime/wanxiang.custom.yaml >/dev/null
        if git_repo diff --cached --quiet -- files; then :; else
            status=$?; ((status == 1)) || exit "$status"
            git_repo commit -m "chore: snapshot Rime configuration $(date +%F)" -- files
        fi
        git_repo push -u origin "HEAD:refs/heads/$branch"
        ;;
    pull) git_repo pull --ff-only; printf 'Repository updated only. Run ./rime.sh install before pushing.\n' ;;
    *) fail 'Usage: ./rime.sh sync push|pull' ;;
    esac
    ;;
help|--help|-h) printf '%s\n' 'Usage: ./rime.sh deps|capture|backup|install|restore ARCHIVE|sync push|sync pull' 'capture stages portable settings; backup preserves full data; install backs up and deploys' 'restore replaces full data after backing up; sync pull never changes live settings' ;;
*) fail "Unknown command: $1" ;;
esac
