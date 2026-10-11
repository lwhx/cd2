#!/usr/bin/env bash
# CloudDrive2 Native Manager for Debian/Ubuntu (systemd, no Docker)
# This is an independent community management script, not affiliated with CloudDrive2.
set -Eeuo pipefail
umask 027

APP_NAME='CloudDrive2 Native Manager'
MANAGER_VERSION='1.3.1'
SERVICE='clouddrive2.service'
SERVICE_USER='clouddrive2'
SERVICE_GROUP='clouddrive2'
UNIT='/etc/systemd/system/clouddrive2.service'
STATE='/etc/clouddrive2-native-manager.conf'
MANAGER_BIN='/usr/local/sbin/cd2-native'
INSTALL_ROOT='/opt/clouddrive2'
CONFIG_LAYOUT='integrated'
LEGACY_DATA_DIR='/var/lib/clouddrive2'
DATA_DIR="$INSTALL_ROOT/config"
BACKUP_DIR='/var/backups/clouddrive2'
MOUNT_DIR='/mnt/clouddrive2'
RELEASE_API='https://api.github.com/repos/cloud-fs/cloud-fs.github.io/releases/latest'
UPDATE_CACHE_DIR='/var/cache/clouddrive2-native-manager'
UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-release"
UPDATE_CACHE_TTL=21600 # Six hours
LOCK_FILE='/run/lock/clouddrive2-native-manager.lock'
PORT='19798'
TMP_WORK=''
TX_ACTIVE=0
TX_OLD=''
TX_BACKUP=''
TX_WAS_RUNNING=0
TX_SWITCHED=0
MIGRATION_ACTIVE=0
MIGRATION_WAS_RUNNING=0

log()  { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

on_exit() {
    local code=$?
    trap - EXIT INT TERM
    set +e
    if (( code != 0 && TX_ACTIVE == 1 )); then
        warn 'Update interrupted or failed. Attempting automatic rollback.'
        systemctl stop "$SERVICE" >/dev/null 2>&1
        if (( TX_SWITCHED == 1 )); then
            if [[ -n "$TX_OLD" ]]; then
                atomic_link current "$TX_OLD"
            else
                rm -f -- "$INSTALL_ROOT/current"
            fi
        fi
        if (( TX_SWITCHED == 1 )) && [[ -n "$TX_BACKUP" && -f "$TX_BACKUP" ]]; then
            restore_data_from_backup "$TX_BACKUP" || warn 'Data recovery failed; inspect backups before proceeding.'
        fi
        if (( TX_WAS_RUNNING == 1 )); then
            systemctl start "$SERVICE" || warn 'Previous version did not start after rollback.'
        fi
    fi
    if (( code != 0 && MIGRATION_ACTIVE == 1 )); then
        warn '配置目录迁移中断。正在恢复旧版配置目录和服务设置。'
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        CONFIG_LAYOUT='legacy'
        DATA_DIR="$LEGACY_DATA_DIR"
        install_service_unit || warn '恢复旧 systemd 单元失败，请手动检查。'
        save_state || warn '恢复旧配置路径记录失败，请手动检查。'
        if (( MIGRATION_WAS_RUNNING == 1 )); then
            systemctl start "$SERVICE" || warn '旧服务没有自动启动，请检查日志。'
        fi
        warn "旧配置未删除：$LEGACY_DATA_DIR；新复制的配置可能保留在 $INSTALL_ROOT/config。"
    fi
    if [[ -n "$TMP_WORK" && -d "$TMP_WORK" ]]; then
        rm -rf -- "$TMP_WORK"
    fi
    exit "$code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_root() {
    (( EUID == 0 )) || { fail 'Please run as root (sudo bash script.sh).'; exit 1; }
    [[ "$(uname -s)" == Linux ]] || { fail 'Linux only.'; exit 1; }
    [[ -d /run/systemd/system ]] || { fail 'systemd must be PID 1. This host does not appear to run systemd.'; exit 1; }
    command -v systemctl >/dev/null || { fail 'systemctl is missing.'; exit 1; }
    [[ -f /etc/os-release ]] || { fail 'Cannot identify operating system.'; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        debian:*|ubuntu:*|*:debian*|*:ubuntu*) ;;
        *) fail 'Only Debian/Ubuntu are supported by the automatic dependency installer.'; exit 1 ;;
    esac
}

valid_install_path() {
    local p="$1"
    [[ "$p" =~ ^/opt/[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || return 1
    [[ "$p" != *//* ]] || return 1
    [[ "$p" != *'/../'* && "$p" != *'/./'* && "$p" != *'/..' && "$p" != *'/.' ]] || return 1
    [[ "$p" != */ && "$p" != /opt/clouddrive2/releases* ]] || return 1
    return 0
}

set_config_dir() {
    case "$CONFIG_LAYOUT" in
        integrated) DATA_DIR="$INSTALL_ROOT/config" ;;
        legacy) DATA_DIR="$LEGACY_DATA_DIR" ;;
        *) fail 'Invalid config layout.'; return 1 ;;
    esac
}

load_state() {
    CONFIG_LAYOUT='integrated'
    if [[ -f "$STATE" ]]; then
        [[ -O "$STATE" && ! -L "$STATE" ]] || { fail 'Managed state file ownership is unsafe.'; exit 1; }
        local loaded layout
        loaded="$(sed -n 's/^INSTALL_ROOT=//p' "$STATE" | head -n 1)"
        [[ -n "$loaded" ]] || { fail 'State file is invalid.'; exit 1; }
        valid_install_path "$loaded" || { fail 'State file contains an invalid install path.'; exit 1; }
        INSTALL_ROOT="$loaded"
        # v1.x state files only had INSTALL_ROOT. Keep their legacy path
        # until an explicit migration; never make an old installation look fresh.
        layout="$(sed -n 's/^CONFIG_LAYOUT=//p' "$STATE" | head -n 1)"
        CONFIG_LAYOUT="${layout:-legacy}"
    fi
    set_config_dir || exit 1
}

save_state() {
    valid_install_path "$INSTALL_ROOT" || return 1
    [[ "$CONFIG_LAYOUT" == integrated || "$CONFIG_LAYOUT" == legacy ]] || return 1
    local t
    t="$(mktemp "$(dirname "$STATE")/.clouddrive2-native.conf.XXXXXX")" || return 1
    printf 'INSTALL_ROOT=%s\nCONFIG_LAYOUT=%s\n' "$INSTALL_ROOT" "$CONFIG_LAYOUT" > "$t"
    chmod 0600 "$t"
    mv -f -- "$t" "$STATE"
}

check_managed() {
    [[ -f "$STATE" && -f "$UNIT" && -L "$INSTALL_ROOT/current" ]] || {
        fail 'No managed native installation found. Run install first.'
        return 1
    }
}

# Keep all deletion targets inside the expected managed filesystem tree.
safe_install_root() {
    valid_install_path "$INSTALL_ROOT" || { fail 'Unsafe installation root.'; return 1; }
    [[ -d "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || { fail 'Invalid or symbolic-link installation root.'; return 1; }
    [[ "$(realpath -e -- "$INSTALL_ROOT")" == "$INSTALL_ROOT" ]] || {
        fail 'Installation root resolves through a symlink or outside its expected path.'
        return 1
    }
}

# Never delete or move an active FUSE/bind mount. In particular, cloud files
# mounted underneath the installation tree must never be traversed by rm.
assert_no_mounts_under() {
    local path="$1" mount targets
    command -v findmnt >/dev/null 2>&1 || { fail 'findmnt is required for safe removal/migration.'; return 1; }
    targets="$(findmnt -rno TARGET 2>/dev/null)" || { fail 'Unable to inspect mount table; refusing file removal.'; return 1; }
    [[ -n "$targets" ]] || { fail 'Mount table unexpectedly empty; refusing file removal.'; return 1; }
    while IFS= read -r mount; do
        if [[ "$mount" == "$path" || "$mount" == "$path/"* ]]; then
            fail "Active mount at $mount; refusing to modify $path."
            return 1
        fi
    done <<< "$targets"
}

safe_legacy_config_path() {
    [[ "$LEGACY_DATA_DIR" == /var/lib/clouddrive2 ]] || { fail 'Unexpected legacy configuration path.'; return 1; }
    [[ ! -L "$LEGACY_DATA_DIR" ]] || { fail 'Legacy configuration is a symlink.'; return 1; }
}

safe_auxiliary_purge_paths() {
    [[ "$BACKUP_DIR" == /var/backups/clouddrive2 &&
       "$UPDATE_CACHE_DIR" == /var/cache/clouddrive2-native-manager ]] || {
        fail 'Unexpected backup/cache path. Refusing purge.'; return 1;
    }
}

arch_name() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        armv7l|armv7) printf 'armv7\n' ;;
        *) fail 'Unsupported CPU architecture.'; return 1 ;;
    esac
}

ensure_dependencies() {
    local missing=0
    local cmd
    for cmd in curl jq tar sha256sum mktemp flock useradd getent; do
        if ! command -v "$cmd" >/dev/null 2>&1; then missing=1; fi
    done
    if ! command -v fusermount3 >/dev/null 2>&1; then missing=1; fi
    if (( missing )); then
        log 'Installing dependencies: curl jq tar ca-certificates fuse3 util-linux passwd.'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl jq tar ca-certificates fuse3 util-linux passwd
    fi
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || { fail 'Another CloudDrive2 manager operation is in progress.'; exit 1; }
}

check_conflicts() {
    [[ ! -e "$STATE" ]] || { fail 'A managed installation already exists.'; return 1; }
    [[ ! -e "$UNIT" ]] || { fail "Service file already exists: $UNIT"; return 1; }
    if systemctl list-unit-files clouddrive.service --no-legend 2>/dev/null | grep -q '^clouddrive.service'; then
        fail 'An existing clouddrive.service was found. Stop and migrate it manually first.'
        return 1
    fi
    if command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])19798$'; then
        fail 'Port 19798 appears to be occupied; check an existing CloudDrive2 instance.'
        return 1
    fi
    if [[ -e "$INSTALL_ROOT" || -L "$INSTALL_ROOT" ]]; then
        safe_install_root || return 1
        local entry
        for entry in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            if [[ "$entry" == "$INSTALL_ROOT/config" && -d "$entry" && ! -L "$entry" ]]; then
                continue
            fi
            # Preserve restore snapshots during keep-data uninstall/reinstall.
            if [[ "$entry" == "$INSTALL_ROOT/config.before-restore-"* && -d "$entry" && ! -L "$entry" ]]; then
                continue
            fi
            fail "Install root contains unmanaged files: $entry"
            return 1
        done
        # A prior keep-data uninstall may leave only the config directory.
        # Reinstalling is allowed so long as no other files are present.
        assert_no_mounts_under "$INSTALL_ROOT" || return 1
    fi
}

fetch_latest() {
    # Emits 4 TAB-separated fields: version, download_url, sha256_digest, size
    local arch="$1" mode="${2:-normal}" payload row filename url digest size version prefix
    local retry=3 connection_timeout=15 max_time=45
    prefix="clouddrive-2-linux-${arch}-"
    # Limit the latency of checks performed when opening the menu.
    if [[ "$mode" == quick ]]; then
        retry=0
        connection_timeout=3
        max_time=6
    fi
    payload="$(curl -fsSL --retry "$retry" --connect-timeout "$connection_timeout" --max-time "$max_time" \
        -H 'Accept: application/vnd.github+json' "$RELEASE_API")" || return 1
    row="$(printf '%s' "$payload" | jq -er --arg prefix "$prefix" '
        [.assets[] | select(.name | startswith($prefix) and endswith(".tgz"))] |
        if length == 1 then .[0] else error("Expected exactly one Linux architecture asset") end |
        [.name, .browser_download_url, (.digest // "none"), (.size // 0)] | @tsv
    ')" || return 1
    IFS=$'\t' read -r filename url digest size <<< "$row"
    [[ "$digest" != none ]] || digest=""
    version="${filename#"$prefix"}"
    version="${version%.tgz}"
    [[ "$version" =~ ^[0-9][0-9A-Za-z._-]{0,59}$ ]] || { fail 'Invalid version returned by GitHub.'; return 1; }
    [[ "$url" == "https://github.com/cloud-fs/cloud-fs.github.io/releases/download/"*"/$filename" ]] || {
        fail 'Unexpected asset URL; refusing download.'; return 1;
    }
    if [[ -n "$digest" && ! "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        fail 'Unexpected release digest format.'; return 1
    fi
    [[ "$size" =~ ^[0-9]+$ ]] || { fail 'Unexpected package size.'; return 1; }
    printf '%s\t%s\t%s\t%s\n' "$version" "$url" "$digest" "$size"
}

valid_release_version() {
    [[ "$1" =~ ^[0-9][0-9A-Za-z._-]{0,59}$ ]]
}

version_is_newer() {
    local installed="$1" latest="$2"
    [[ "$installed" != "$latest" ]] || return 1
    valid_release_version "$installed" && valid_release_version "$latest" || return 1
    [[ "$(printf '%s\n' "$installed" "$latest" | LC_ALL=C sort -V | tail -n 1)" == "$latest" ]]
}

managed_install_present() {
    [[ -f "$STATE" && -f "$UNIT" && -L "$INSTALL_ROOT/current" ]]
}

write_latest_cache() {
    local version="$1" tmp
    valid_release_version "$version" || return 1
    [[ ! -L "$UPDATE_CACHE_DIR" && ! -L "$UPDATE_CACHE_FILE" ]] || return 1
    install -d -m 0700 "$UPDATE_CACHE_DIR" || return 1
    tmp="$(mktemp "$UPDATE_CACHE_DIR/.latest.XXXXXXXX")" || return 1
    if ! printf '%s\n' "$version" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$UPDATE_CACHE_FILE" || { rm -f -- "$tmp"; return 1; }
}

read_fresh_latest_cache() {
    local modified now latest
    [[ -f "$UPDATE_CACHE_FILE" && ! -L "$UPDATE_CACHE_FILE" ]] || return 1
    modified="$(stat -c %Y "$UPDATE_CACHE_FILE" 2>/dev/null)" || return 1
    now="$(date +%s)"
    [[ "$modified" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
    (( now >= modified && now - modified < UPDATE_CACHE_TTL )) || return 1
    IFS= read -r latest < "$UPDATE_CACHE_FILE" || return 1
    valid_release_version "$latest" || return 1
    printf '%s\n' "$latest"
}

get_latest_release_cached() {
    local arch meta version remainder
    if read_fresh_latest_cache; then return 0; fi
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    arch="$(arch_name)" || return 1
    meta="$(fetch_latest "$arch" quick)" || return 1
    IFS=$'\t' read -r version remainder <<< "$meta"
    valid_release_version "$version" || return 1
    write_latest_cache "$version" || true
    printf '%s\n' "$version"
}

auto_update_notice() {
    local installed="$1" latest="$2"
    if [[ "$installed" == not-installed ]]; then
        printf '未安装（安装时将获取官方最新版本）\n'
    elif [[ -z "$latest" ]]; then
        printf '检测失败或网络不可用，可选 11 → 1 手动检查\n'
    elif [[ "$installed" == "$latest" ]]; then
        printf '已是最新版本 %s\n' "$installed"
    elif version_is_newer "$installed" "$latest"; then
        printf '发现新版本 %s → %s！选择 2 更新\n' "$installed" "$latest"
    else
        printf '本地 %s / 官方最新 %s（本地不低于官方最新）\n' "$installed" "$latest"
    fi
}

current_version() {
    local f="$INSTALL_ROOT/current/.native-version"
    if [[ -f "$f" ]]; then
        cat "$f"
    elif [[ -L "$INSTALL_ROOT/current" ]]; then
        basename -- "$(readlink "$INSTALL_ROOT/current")"
    else
        printf 'not-installed\n'
    fi
}

atomic_link() {
    local name="$1" target="$2" t
    t="$INSTALL_ROOT/.${name}.next.$$"
    [[ "$name" == current || "$name" == previous ]] || return 1
    [[ "$target" == releases/* && "$target" != *..* ]] || return 1
    [[ -d "$INSTALL_ROOT/$target" ]] || return 1
    ln -s -- "$target" "$t" || return 1
    mv -Tf -- "$t" "$INSTALL_ROOT/$name"
}

safe_archive_contents() {
    local archive="$1" expected="$2" listing name
    listing="$(mktemp)" || return 1
    if ! tar -tzf "$archive" > "$listing"; then rm -f "$listing"; return 1; fi
    while IFS= read -r name; do
        name="${name#./}"
        [[ "$name" == "$expected" || "$name" == "$expected/" || "$name" == "$expected/"* ]] || {
            warn "Archive has unexpected entry: $name"; rm -f "$listing"; return 1;
        }
        [[ "$name" != /* && "$name" != *'/../'* && "$name" != *'/./'* && "$name" != *'/..' ]] || {
            warn "Archive has unsafe entry: $name"; rm -f "$listing"; return 1;
        }
    done < "$listing"
    rm -f "$listing"
}

prepare_release() {
    local version="$1" url="$2" digest="$3" expected_size="$4"
    local archive extracted binary payload actual checksum existing
    [[ ! -d "$INSTALL_ROOT/releases/$version" ]] || return 0
    TMP_WORK="$(mktemp -d "$INSTALL_ROOT/.stage.XXXXXX")"
    archive="$TMP_WORK/download.tgz"
    extracted="$TMP_WORK/unpacked"
    mkdir -p "$extracted"
    log "Downloading official Linux release $version ..."
    curl -fL --retry 3 --connect-timeout 15 --max-time 1800 --progress-bar "$url" -o "$archive"
    [[ -s "$archive" ]] || { fail 'Downloaded archive is empty.'; return 1; }
    if [[ "$expected_size" -gt 0 ]]; then
        actual="$(stat -c '%s' "$archive")"
        [[ "$actual" == "$expected_size" ]] || { fail 'Downloaded size does not match GitHub release metadata.'; return 1; }
    fi
    checksum="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ -n "$digest" ]]; then
        [[ "sha256:$checksum" == "$digest" ]] || { fail 'SHA256 digest mismatch.'; return 1; }
    else
        warn 'GitHub did not provide a SHA256 digest. HTTPS and archive structure are checked.'
    fi
    # Official archive entries must stay inside one top-level package folder.
    tar -tzf "$archive" > "$TMP_WORK/listing"
    while IFS= read -r item; do
        [[ "$item" != /* && "$item" != *'/../'* && "$item" != *'/./'* && "$item" != *'/..' ]] || {
            fail "Unsafe release archive entry: $item"; return 1;
        }
    done < "$TMP_WORK/listing"
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$extracted"
    binary="$(find "$extracted" -type f -name clouddrive -print -quit)"
    [[ -n "$binary" ]] || { fail 'No clouddrive binary found in the downloaded archive.'; return 1; }
    payload="$(dirname "$binary")"
    [[ -d "$payload" ]] || return 1
    chmod 0755 "$binary"
    printf '%s\n' "$version" > "$payload/.native-version"
    printf '%s\n' "$checksum" > "$payload/.native-archive-sha256"
    # Root owns program files, but the unprivileged systemd user must be able
    # to traverse release directories and read the bundled resources.
    chown -R root:root "$payload"
    chmod -R a+rX "$payload"
    chmod 0755 "$binary"
    mv -- "$payload" "$INSTALL_ROOT/releases/$version"
    log "Prepared release $version."
    rm -rf -- "$TMP_WORK"
    TMP_WORK=''
}

ensure_system_user() {
    if ! getent passwd "$SERVICE_USER" >/dev/null; then
        useradd --system --user-group --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    getent group "$SERVICE_GROUP" >/dev/null || { fail 'Service group not found.'; return 1; }
    install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR"
    install -d -m 0700 -o root -g root "$BACKUP_DIR"
    if [[ ! -e "$MOUNT_DIR" ]]; then
        install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$MOUNT_DIR"
    else
        warn "Mount directory exists; leaving existing permissions unchanged: $MOUNT_DIR"
    fi
    if [[ ! -e /dev/fuse ]]; then
        warn '/dev/fuse is missing. Web UI may work, but Linux FUSE mounting will not.'
    fi
}

make_service_unit() {
    local path="$1" output="$2"
    cat > "$output" <<EOF
[Unit]
Description=CloudDrive2 Native Core Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
Environment=CLOUDDRIVE_HOME=$DATA_DIR
WorkingDirectory=$path/current
ExecStart=$path/current/clouddrive
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=65535
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

install_service_unit() {
    local t
    t="$(mktemp "$(dirname "$UNIT")/.clouddrive2.service.XXXXXX")" || return 1
    if ! make_service_unit "$INSTALL_ROOT" "$t" ||
       ! chmod 0644 "$t" ||
       ! mv -f -- "$t" "$UNIT"; then
        rm -f -- "$t"
        return 1
    fi
    systemctl daemon-reload || return 1
}

service_running() {
    systemctl is-active --quiet "$SERVICE"
}

wait_healthy() {
    # Confirm the same systemd main PID stays running for several seconds.
    # This catches many crash/restart loops that a single is-active cannot.
    local attempt pid sample stable
    for (( attempt=1; attempt<=25; attempt++ )); do
        if service_running; then
            pid="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
                stable=1
                for (( sample=0; sample<5; sample++ )); do
                    sleep 1
                    if ! service_running || [[ "$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)" != "$pid" ]]; then
                        stable=0
                        break
                    fi
                done
                if (( stable == 1 )); then return 0; fi
            fi
        fi
        sleep 1
    done
    return 1
}

http_responds() {
    curl -fsSL --max-time 4 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null
}

wait_http() {
    local attempt
    for (( attempt=1; attempt<=20; attempt++ )); do
        http_responds && return 0
        sleep 1
    done
    return 1
}

optional_http_probe() {
    if http_responds; then
        log "Local Web UI responds at http://127.0.0.1:$PORT/"
    else
        warn 'Service is active but default Web UI port did not respond. Check customized ports or logs.'
    fi
}

backup_data() {
    local prefix="$1" datepart archive t base
    install -d -m 0700 "$BACKUP_DIR"
    datepart="$(date -u +'%Y%m%dT%H%M%SZ')"
    archive="$BACKUP_DIR/${prefix}-${datepart}-$$.tar.gz"
    t="$(mktemp "$BACKUP_DIR/.backup.partial.XXXXXX")" || return 1
    base="$(basename "$DATA_DIR")"
    log "Backing up $DATA_DIR ..."
    if ! tar --one-file-system --numeric-owner -czf "$t" -C "$(dirname "$DATA_DIR")" "$base"; then
        rm -f -- "$t"; return 1
    fi
    if ! mv -f -- "$t" "$archive"; then rm -f -- "$t"; return 1; fi
    if ! (cd "$BACKUP_DIR" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"); then
        warn 'Backup archive saved, but checksum creation failed.'
        return 1
    fi
    chmod 0600 "$archive" "$archive.sha256"
    printf '%s\n' "$archive"
}

backup_payload_name() {
    local archive="$1" item root
    item="$(tar -tzf "$archive" 2>/dev/null | sed -n '1p')" || return 1
    item="${item#./}"
    root="${item%%/*}"
    [[ "$root" == config || "$root" == clouddrive2 ]] || return 1
    printf '%s\n' "$root"
}

verify_backup() {
    local archive="$1" basename_archive root
    [[ -f "$archive" && ! -L "$archive" ]] || { fail 'Backup archive missing or symbolic link.'; return 1; }
    [[ "$(dirname "$archive")" == "$BACKUP_DIR" ]] || { fail 'Only manager backups can be restored.'; return 1; }
    basename_archive="$(basename "$archive")"
    [[ "$basename_archive" == *.tar.gz && -f "$archive.sha256" ]] || {
        fail 'A matching .sha256 file is required.'; return 1;
    }
    (cd "$BACKUP_DIR" && sha256sum -c --status "${basename_archive}.sha256") || {
        fail 'Backup SHA256 check failed.'; return 1;
    }
    root="$(backup_payload_name "$archive")" || {
        fail 'Backup has an unrecognized payload directory.'; return 1;
    }
    safe_archive_contents "$archive" "$root" || return 1
}


restore_data_from_backup() {
    # Caller must stop the service before calling this function.
    local archive="$1" stage extracted old suffix base
    verify_backup "$archive" || return 1
    stage="$(mktemp -d "$(dirname "$DATA_DIR")/.clouddrive2-restore.XXXXXX")" || return 1
    assert_no_mounts_under "$DATA_DIR" || return 1
    base="$(backup_payload_name "$archive")" || return 1
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$stage"; then
        rm -rf -- "$stage"; return 1
    fi
    extracted="$stage/$base"
    [[ -d "$extracted" && ! -L "$extracted" ]] || { rm -rf -- "$stage"; return 1; }
    if ! chown -R "$SERVICE_USER:$SERVICE_GROUP" "$extracted"; then
        rm -rf -- "$stage"; return 1
    fi
    suffix="$(date -u +'%Y%m%dT%H%M%SZ')-$$"
    old="${DATA_DIR}.before-restore-$suffix"
    if [[ -e "$DATA_DIR" ]]; then
        mv -- "$DATA_DIR" "$old" || { rm -rf -- "$stage"; return 1; }
    else
        old=''
    fi
    if ! mv -- "$extracted" "$DATA_DIR"; then
        [[ -z "$old" ]] || mv -- "$old" "$DATA_DIR"
        rm -rf -- "$stage"; return 1
    fi
    rmdir -- "$stage" 2>/dev/null || true
    if [[ -n "$old" ]]; then
        warn "Previous data directory was preserved at: $old"
    fi
    log 'Configuration/data restore completed.'
}

find_backup() {
    local arg="${1:-latest}" resolved
    if [[ "$arg" == latest ]]; then
        resolved="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d ' ' -f 2-)"
    else
        [[ "$arg" != */* && "$arg" != *'..'* ]] || return 1
        resolved="$BACKUP_DIR/$arg"
    fi
    [[ -n "$resolved" && -f "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

do_install() {
    check_conflicts
    ensure_dependencies
    local arch version url digest size meta
    arch="$(arch_name)"
    meta="$(fetch_latest "$arch")" || { fail 'Failed to query the official GitHub release.'; return 1; }
    IFS=$'\t' read -r version url digest size <<< "$meta"
    mkdir -p "$INSTALL_ROOT/releases"
    chmod 0755 "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
    prepare_release "$version" "$url" "$digest" "$size"
    ensure_system_user
    atomic_link current "releases/$version"
    install_service_unit
    save_state
    systemctl enable "$SERVICE"
    if ! systemctl start "$SERVICE" || ! wait_healthy; then
        warn 'Service did not start. Files and configuration were preserved for diagnosis.'
        systemctl --no-pager -l status "$SERVICE" || true
        return 1
    fi
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
        install -m 0755 "${BASH_SOURCE[0]}" "$MANAGER_BIN"
    fi
    optional_http_probe
    write_latest_cache "$version" || true
    log "Installation complete. Version: $version"
    log "Core directory: $INSTALL_ROOT/current"
    log "Local configuration: $DATA_DIR"
    log "Configuration backups: $BACKUP_DIR"
    log "Management command: $MANAGER_BIN"
    log "Web UI: http://YOUR_SERVER_IP:$PORT"
    log "Suggested FUSE mount directory: $MOUNT_DIR (configure in the Web UI)"
}

do_check() {
    check_managed
    local installed arch meta version url digest size
    installed="$(current_version)"
    arch="$(arch_name)"
    meta="$(fetch_latest "$arch")" || { fail 'Cannot query the official release.'; return 1; }
    IFS=$'\t' read -r version url digest size <<< "$meta"
    write_latest_cache "$version" || true
    printf 'Installed: %s\nOfficial latest: %s\n' "$installed" "$version"
    if [[ "$installed" == "$version" ]]; then
        log 'Already up to date.'
    elif version_is_newer "$installed" "$version"; then
        log 'An update is available.'
    else
        warn 'Installed core is not older than the latest official release.'
    fi
}

do_update() {
    check_managed
    ensure_dependencies
    local arch meta version url digest size old old_version backup expect_http=0
    arch="$(arch_name)"
    meta="$(fetch_latest "$arch")" || { fail 'Could not query the official release.'; return 1; }
    IFS=$'\t' read -r version url digest size <<< "$meta"
    old_version="$(current_version)"
    if [[ "$old_version" == "$version" ]]; then
        write_latest_cache "$version" || true
        log "Already at latest version $version."
        return 0
    fi
    if ! version_is_newer "$old_version" "$version"; then
        fail "Installed core $old_version is not older than official latest $version; refusing automatic downgrade."
        return 1
    fi
    log "Updating $old_version -> $version"
    prepare_release "$version" "$url" "$digest" "$size"
    old="$(readlink "$INSTALL_ROOT/current")"
    TX_OLD="$old"
    if service_running; then
        TX_WAS_RUNNING=1
        if http_responds; then expect_http=1; fi
    else
        TX_WAS_RUNNING=0
    fi
    TX_ACTIVE=1
    if (( TX_WAS_RUNNING == 1 )); then systemctl stop "$SERVICE"; fi
    backup="$(backup_data "preupdate-${old_version}-to-${version}")"
    TX_BACKUP="$backup"
    log "Upgrade backup: $backup"
    atomic_link previous "$old"
    atomic_link current "releases/$version"
    TX_SWITCHED=1
    if (( TX_WAS_RUNNING == 1 )); then
        if ! systemctl start "$SERVICE" || ! wait_healthy; then
            fail 'New release failed to start.'
            return 1
        fi
        if (( expect_http == 1 )) && ! wait_http; then
            fail 'The default Web UI responded before the update, but not afterward.'
            return 1
        fi
        optional_http_probe
    else
        warn 'The service was stopped before updating; not starting it automatically.'
    fi
    TX_ACTIVE=0
    write_latest_cache "$version" || true
    log "Successfully updated to $version."
    log "Previous version retained at: $INSTALL_ROOT/$old"
}

do_backup() {
    check_managed
    local was_running=0 result
    if service_running; then was_running=1; systemctl stop "$SERVICE"; fi
    if ! result="$(backup_data manual)"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        fail 'Backup failed.'
        return 1
    fi
    if (( was_running )); then systemctl start "$SERVICE"; fi
    log "Backup created: $result"
}

do_restore() {
    check_managed
    local arg="${1:-latest}" backup was_running=0
    backup="$(find_backup "$arg")" || { fail 'Backup not found. Use backups to list archives.'; return 1; }
    verify_backup "$backup" || return 1
    warn "Restoring $backup. The current configuration/data will be preserved in a sibling directory."
    if service_running; then was_running=1; systemctl stop "$SERVICE"; fi
    if ! restore_data_from_backup "$backup"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        return 1
    fi
    if (( was_running )); then
        systemctl start "$SERVICE"
        if ! wait_healthy; then warn 'Restored version is not healthy. Inspect logs.'; return 1; fi
    fi
    log 'Restore complete.'
}

do_rollback() {
    check_managed
    local old target backup was_running=0
    [[ -L "$INSTALL_ROOT/previous" ]] || { fail 'There is no previous release.'; return 1; }
    target="$(readlink "$INSTALL_ROOT/previous")"
    old="$(readlink "$INSTALL_ROOT/current")"
    [[ "$target" != "$old" ]] || { fail 'Previous and current releases are the same.'; return 1; }
    warn "Rolling binary back from $old to $target. Configuration is NOT automatically reverted."
    if service_running; then was_running=1; systemctl stop "$SERVICE"; fi
    if ! backup="$(backup_data pre-rollback)"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        return 1
    fi
    TX_ACTIVE=1
    TX_OLD="$old"
    TX_BACKUP="$backup"
    TX_WAS_RUNNING="$was_running"
    atomic_link current "$target"
    TX_SWITCHED=1
    if (( was_running )); then
        if ! systemctl start "$SERVICE" || ! wait_healthy; then
            fail 'Rollback release failed to start.'
            return 1
        fi
    fi
    atomic_link previous "$old"
    TX_ACTIVE=0
    log "Binary rollback complete. Current release: $(current_version)"
    warn 'If an older version cannot read a newer configuration, restore the matching preupdate backup.'
}

show_backups() {
    check_managed
    printf '%s\n' 'Backup archives (newest first):'
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %f\n' 2>/dev/null | sort -nr | cut -d ' ' -f 2-
}

do_uninstall() {
    check_managed
    local mode="${1:-}" answer
    [[ "$mode" == '' || "$mode" == '--yes' || "$mode" == '--purge' ]] || {
        fail 'Usage: uninstall [--yes | --purge]'; return 1;
    }
    printf '\n'
    if [[ "$mode" == '--purge' ]]; then
        printf '【危险操作】将删除此设备上的 CloudDrive2 程序、配置、缓存和管理备份。\n'
        printf '删除范围：%s、%s、%s、%s\n' "$INSTALL_ROOT" "$DATA_DIR" "$BACKUP_DIR" "$UPDATE_CACHE_DIR"
        printf '不会删除远端网盘文件，也不会删除或遍历 %s。\n' "$MOUNT_DIR"
        printf '重要：删除备份后无法再通过管理脚本恢复原有配置。\n'
        printf '确认删除全部本地数据，请输入 yes: '
        IFS= read -r answer || return 1
        [[ "$answer" == yes ]] || { warn '已取消彻底卸载。'; return 0; }
    elif [[ "$mode" != '--yes' ]]; then
        printf '仅卸载程序，保留本地配置、备份和挂载目录。确认请输入 UNINSTALL: '
        IFS= read -r answer || return 1
        [[ "$answer" == UNINSTALL ]] || { warn '已取消卸载。'; return 0; }
    fi

    # Check every path BEFORE stopping service or touching the systemd unit.
    safe_install_root || return 1
    assert_no_mounts_under "$INSTALL_ROOT" || return 1
    if [[ "$mode" == '--purge' ]]; then
        assert_no_mounts_under "$BACKUP_DIR" || return 1
        assert_no_mounts_under "$UPDATE_CACHE_DIR" || return 1
        if [[ "$CONFIG_LAYOUT" == legacy ]]; then
            safe_legacy_config_path || return 1
            assert_no_mounts_under "$LEGACY_DATA_DIR" || return 1
        fi
        safe_auxiliary_purge_paths || return 1
    fi

    if ! systemctl stop "$SERVICE" || service_running; then
        fail 'Service is still running; refusing uninstall to protect active mounts.'
        return 1
    fi
    # CloudDrive2 might not have released the mounts immediately on SIGTERM.
    assert_no_mounts_under "$INSTALL_ROOT" || return 1
    systemctl disable "$SERVICE" || true
    rm -f -- "$UNIT"
    systemctl daemon-reload

    if [[ "$mode" == '--purge' ]]; then
        rm -rf --one-file-system -- "$INSTALL_ROOT" || return 1
        if [[ "$CONFIG_LAYOUT" == legacy && -e "$LEGACY_DATA_DIR" ]]; then
            safe_legacy_config_path || return 1
            assert_no_mounts_under "$LEGACY_DATA_DIR" || return 1
            rm -rf --one-file-system -- "$LEGACY_DATA_DIR" || return 1
        fi
        assert_no_mounts_under "$BACKUP_DIR" || return 1
        assert_no_mounts_under "$UPDATE_CACHE_DIR" || return 1
        rm -rf --one-file-system -- "$BACKUP_DIR" "$UPDATE_CACHE_DIR" || return 1
        log 'CloudDrive2 程序及本地配置、备份、缓存已删除。'
        log "未触碰云端文件及挂载目录：$MOUNT_DIR"
    else
        # Removing the install root would also erase its integrated config.
        # Remove only manager-owned binary artifacts and leave config untouched.
        rm -f -- "$INSTALL_ROOT/current" "$INSTALL_ROOT/previous"
        rm -rf --one-file-system -- "$INSTALL_ROOT/releases" || return 1
        log "程序已卸载，本地配置仍保留在：$DATA_DIR"
        log "管理备份保留在：$BACKUP_DIR"
        log "云盘挂载位置保持不变：$MOUNT_DIR"
    fi
    rm -f -- "$STATE"
    log "管理命令仍保留在：$MANAGER_BIN"
}


do_relocate() {
    check_managed
    local target="$1" source="$INSTALL_ROOT" was_running=0
    valid_install_path "$target" || { fail 'Target must be a clean absolute path below /opt.'; return 1; }
    [[ ! -e "$target" && ! -L "$target" ]] || { fail 'Target already exists.'; return 1; }
    safe_install_root || return 1
    assert_no_mounts_under "$source" || return 1
    if service_running; then was_running=1; systemctl stop "$SERVICE"; fi
    mkdir -p "$(dirname "$target")"
    local resolved_parent
    resolved_parent="$(realpath -e "$(dirname "$target")")"
    [[ "$resolved_parent" == /opt || "$resolved_parent" == /opt/* ]] || {
        fail 'Relocate destination resolves outside /opt.'; return 1;
    }
    [[ "$(stat -c '%d' "$source")" == "$(stat -c '%d' "$resolved_parent")" ]] || {
        fail 'Relocation across filesystems is not supported.'; return 1;
    }
    if ! mv -- "$source" "$target"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        fail 'Moving installation failed.'; return 1
    fi
    INSTALL_ROOT="$target"
    set_config_dir
    if ! install_service_unit; then
        INSTALL_ROOT="$source"; set_config_dir
        mv -- "$target" "$source" || true
        install_service_unit || true
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        return 1
    fi
    if (( was_running )); then
        if ! systemctl start "$SERVICE" || ! wait_healthy; then
            systemctl stop "$SERVICE" || true
            INSTALL_ROOT="$source"; set_config_dir
            mv -- "$target" "$source" || true
            install_service_unit || true
            systemctl start "$SERVICE" || true
            fail 'Relocated service failed health check. Original location restored.'
            return 1
        fi
    fi
    save_state
    log "程序与配置目录已迁移到 $INSTALL_ROOT。"
    log "配置目录：$DATA_DIR；备份和挂载目录未迁移。"
}


do_migrate_config() {
    check_managed
    if [[ "$CONFIG_LAYOUT" == integrated ]]; then
        log "配置已位于程序目录：$DATA_DIR"
        return 0
    fi
    [[ "$CONFIG_LAYOUT" == legacy ]] || { fail 'Unsupported layout.'; return 1; }
    safe_install_root || return 1
    safe_legacy_config_path || return 1
    [[ -d "$LEGACY_DATA_DIR" ]] || { fail '找不到旧版配置目录。'; return 1; }
    [[ ! -e "$INSTALL_ROOT/config" && ! -L "$INSTALL_ROOT/config" ]] || {
        fail "目标配置目录已存在，拒绝覆盖：$INSTALL_ROOT/config"; return 1;
    }
    assert_no_mounts_under "$LEGACY_DATA_DIR" || return 1
    assert_no_mounts_under "$INSTALL_ROOT" || return 1

    local was_running=0 backup stage
    if service_running; then
        was_running=1
        systemctl stop "$SERVICE" || return 1
    fi
    if ! backup="$(backup_data pre-config-migration)"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        fail '迁移前备份失败，保留旧配置。'
        return 1
    fi
    log "迁移前备份：$backup"
    if ! stage="$(mktemp -d "$INSTALL_ROOT/.migrate-config.XXXXXX")"; then
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        return 1
    fi
    if ! cp -a -- "$LEGACY_DATA_DIR" "$stage/config"; then
        rm -rf --one-file-system -- "$stage"
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        fail '复制配置失败，保留旧目录。'; return 1
    fi
    if ! mv -- "$stage/config" "$INSTALL_ROOT/config"; then
        rm -rf --one-file-system -- "$stage"
        if (( was_running )); then systemctl start "$SERVICE" || true; fi
        fail '放置新配置目录失败，保留旧目录。'; return 1
    fi
    rmdir -- "$stage" || true
    MIGRATION_ACTIVE=1
    MIGRATION_WAS_RUNNING="$was_running"
    CONFIG_LAYOUT=integrated
    set_config_dir || return 1
    install_service_unit || return 1
    save_state || return 1
    # Validate the migrated config under the new CLOUDDRIVE_HOME even if the
    # service was previously stopped, then restore its prior stopped state.
    systemctl start "$SERVICE" || return 1
    if ! wait_healthy; then
        fail '迁移后服务未通过健康检查，正在恢复旧配置路径。'
        return 1
    fi
    if (( was_running == 0 )); then systemctl stop "$SERVICE" || return 1; fi
    MIGRATION_ACTIVE=0
    # Once the new instance is healthy, the original copy may be removed.
    # The migration backup remains in BACKUP_DIR.
    safe_legacy_config_path || return 1
    assert_no_mounts_under "$LEGACY_DATA_DIR" || return 1
    rm -rf --one-file-system -- "$LEGACY_DATA_DIR" || {
        warn "已迁移成功，但清理旧目录失败，请检查：$LEGACY_DATA_DIR"
        return 0
    }
    log "配置目录迁移成功：$DATA_DIR"
    log "可从备份恢复原配置：$backup"
}

show_status() {
    printf 'Installed version: %s\n' "$(current_version)"
    printf 'Install root: %s\nConfig directory: %s\nConfig layout: %s\nBackup directory: %s\nMount target: %s\n' \
        "$INSTALL_ROOT" "$DATA_DIR" "$CONFIG_LAYOUT" "$BACKUP_DIR" "$MOUNT_DIR"
    printf 'FUSE device: '
    if [[ -e /dev/fuse ]]; then printf 'available\n'; else printf 'missing\n'; fi
    systemctl --no-pager -l status "$SERVICE" || true
}

enable_allow_other() {
    check_managed
    [[ -f /etc/fuse.conf ]] || touch /etc/fuse.conf
    if grep -Eq '^[[:space:]]*user_allow_other([[:space:]]*(#.*)?)?$' /etc/fuse.conf; then
        log 'user_allow_other is already enabled.'
        return 0
    fi
    cp -a -- /etc/fuse.conf "/etc/fuse.conf.cd2-backup-$(date -u +'%Y%m%dT%H%M%SZ')"
    printf '\n# Enabled on request by CloudDrive2 Native Manager\nuser_allow_other\n' >> /etc/fuse.conf
    log 'Enabled user_allow_other. In the Web UI, set mount permissions/allow_other as needed.'
}

usage() {
    cat <<'EOF'
CloudDrive2 Native Manager (Debian/Ubuntu)
Usage: sudo bash clouddrive2-manager.sh <command>
Commands:
  menu                 Interactive numbered management menu (default)
  install              Install latest native release + systemd service
  check                Compare installed/latest GitHub release versions
  update               Update with data backup + automatic failure rollback
  rollback             Switch back to the previous binary release
  version              Print installed binary version
  status               Show systemd status and installation paths
  start|stop|restart   Manage systemd service
  logs                 Follow systemd logs
  logs-tail            Show last 80 lines without following
  backup               Consistent full data directory backup (brief service stop)
  backups              List local backup archives
  restore [latest|NAME] Restore a verified manager backup (brief service stop)
  enable-allow-other   Permit non-root users to request FUSE allow_other
  relocate /opt/PATH   Move binaries and integrated config together
  migrate-config       Migrate an existing v1.x config to /opt/PROGRAM/config
  uninstall [--yes]    Remove program/service; retain config/backups/mounts
  uninstall --purge    Delete ALL local CloudDrive2 program/config/backups/cache
                       (requires typed confirmation; NEVER deletes cloud/mount)
  system-info          Print system and mount status
  about                Print manager information
  help                 Show this help
EOF
}

run_menu_command() {
    # Execute management actions in a separate process so that errors and
    # transaction/rollback EXIT traps never terminate the interactive menu.
    local source_file="${BASH_SOURCE[0]}"
    if (( EUID != 0 )); then
        warn '管理操作需要 root 权限。请使用 sudo bash clouddrive2-manager.sh 或 sudo cd2-native。'
        return 1
    fi
    if [[ ! -f "$source_file" ]]; then
        warn '无法重新打开脚本文件。请先下载脚本到磁盘后运行，不要通过管道或 bash <(...) 交互运行。'
        return 1
    fi
    if ! bash "$source_file" "$@"; then
        warn '操作未成功，请查看以上报错及服务日志。'
        return 1
    fi
}

menu_pause() {
    local ignored
    if [[ -t 0 && -t 1 ]]; then
        printf '\n按回车键返回菜单...'
        IFS= read -r ignored || true
    fi
}

menu_action() {
    printf '\n'
    run_menu_command "$@" || true
    menu_pause
}

menu_confirm() {
    local answer
    printf '%s [y/N]: ' "$1"
    IFS= read -r answer || return 1
    [[ "$answer" == y || "$answer" == Y ]]
}

menu_uninstall() {
    local option
    while true; do
        printf '\nCloudDrive2 卸载选项：\n'
        printf '1、仅卸载程序（保留配置、缓存和备份，可重新安装）\n'
        printf '2、卸载并删除全部本地数据（配置、缓存、备份均删除）\n'
        printf '0、返回主菜单\n'
        printf '%s\n' '-------------------'
        printf '远端网盘文件与 %s 挂载目录始终不会删除。\n' "$MOUNT_DIR"
        printf '请输入选项 [0-2]: '
        IFS= read -r option || return 0
        case "$option" in
            1) menu_action uninstall; return 0 ;;
            2) menu_action uninstall --purge; return 0 ;;
            0) return 0 ;;
            *) warn '无效选项，请输入 0-2。'; menu_pause ;;
        esac
    done
}

menu_restore() {
    local archive
    printf '\n当前可用备份：\n'
    run_menu_command backups || true
    printf '\n请输入备份文件名（直接回车使用最新备份，输入 0 取消）: '
    IFS= read -r archive || return 0
    if [[ "$archive" == 0 ]]; then return 0; fi
    if menu_confirm '确认恢复备份？恢复过程中服务会暂时停止'; then
        menu_action restore "${archive:-latest}"
    else
        warn '已取消恢复。'
        menu_pause
    fi
}

menu_version_management() {
    local choice
    while true; do
        printf '\n版本管理：\n'
        printf '1、检查官方最新版本\n2、查看当前版本\n3、回滚到上一版本\n4、查看备份列表\n'
        printf '%s\n' '-------------------'
        printf '0、返回主菜单\n\n请输入选项 [0-4]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) menu_action check ;;
            2) menu_action version ;;
            3) if menu_confirm '确定要回滚到上一版本吗？'; then menu_action rollback
               else warn '已取消回滚。'; menu_pause; fi ;;
            4) menu_action backups ;;
            0) return 0 ;;
            *) warn '无效选项，请输入 0-4。'; menu_pause ;;
        esac
    done
}

show_mount_info() {
    printf '\nFUSE 挂载信息：\n'
    printf '挂载目录：%s\n' "$MOUNT_DIR"
    if [[ -e /dev/fuse ]]; then printf 'FUSE 设备：已存在\n'
    else printf 'FUSE 设备：缺失（本地挂载不可用）\n'; fi
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_DIR"; then
        printf '挂载状态：已挂载\n'
        if command -v findmnt >/dev/null 2>&1; then
            findmnt -T "$MOUNT_DIR" -o SOURCE,TARGET,FSTYPE || true
        fi
    else
        printf '挂载状态：未挂载（需在 CloudDrive2 网页中创建挂载点）\n'
    fi
}

menu_advanced_management() {
    local choice target
    while true; do
        printf '\n挂载与高级设置：\n'
        printf '1、启用 FUSE allow_other\n2、迁移程序安装目录\n3、查看本地挂载状态\n4、迁移旧版配置到程序目录\n'
        printf '%s\n' '-------------------'
        printf '0、返回主菜单\n\n请输入选项 [0-4]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) menu_action enable-allow-other ;;
            2)
                printf '请输入新安装目录（必须位于 /opt 下，输入 0 取消）: '
                IFS= read -r target || return 0
                if [[ "$target" != 0 && -n "$target" ]]; then
                    menu_action relocate "$target"
                else
                    warn '已取消迁移。'
                    menu_pause
                fi
                ;;
            3) show_mount_info; menu_pause ;;
            4) if menu_confirm '确定要备份并迁移旧版配置到程序目录吗？'; then
                    menu_action migrate-config
               else warn '已取消配置迁移。'; menu_pause
               fi ;;
            0) return 0 ;;
            *) warn '无效选项，请输入 0-4。'; menu_pause ;;
        esac
    done
}

show_system_info() {
    printf '\n系统状态：\n'
    if [[ -r /etc/os-release ]]; then
        local os
        os="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n 1)"
        os="${os#\"}"
        os="${os%\"}"
        printf '操作系统：%s\n' "$os"
    fi
    printf '内核版本：%s\n' "$(uname -r)"
    printf '处理器架构：%s\n' "$(uname -m)"
    printf 'CloudDrive2：%s\n' "$(current_version)"
    printf '程序目录：%s/current\n' "$INSTALL_ROOT"
    printf '配置目录：%s\n' "$DATA_DIR"
    printf '备份目录：%s\n' "$BACKUP_DIR"
    if [[ -f "$UNIT" ]]; then
        if service_running; then printf '服务状态：运行中\n'
        else printf '服务状态：未运行\n'; fi
    else
        printf '服务状态：未安装\n'
    fi
    if [[ -e /dev/fuse ]]; then printf 'FUSE 设备：存在\n'
    else printf 'FUSE 设备：缺失\n'; fi
    if command -v free >/dev/null 2>&1; then
        printf '\n内存使用：\n'
        free -h
    fi
    if command -v df >/dev/null 2>&1; then
        printf '\n系统分区：\n'
        df -h /
    fi
    show_mount_info
}

show_about() {
    printf '\n关于 CloudDrive2 原生管理脚本\n'
    printf '管理脚本版本：v%s\n' "$MANAGER_VERSION"
    printf '部署方式：Linux 原生二进制 + systemd（不使用 Docker）\n'
    printf '官方核心版本：%s\n' "$(current_version)"
    printf '项目仓库：https://github.com/lwhx/cd2\n'
    printf 'CloudDrive2 官网：https://www.clouddrive2.com/\n'
    printf '说明：这是第三方管理脚本，不是 CloudDrive2 官方安装器。\n'
    printf '提示：管理员密码请在 CloudDrive2 网页中管理；Docker 管理不适用于原生部署。\n'
    printf '安全：升级前会备份数据；卸载默认保留用户配置、备份和挂载目录。\n'
}

menu() {
    local choice state installed_version last_checked_version='__unchecked__'
    local latest_seen='' update_notice='尚未安装'
    while true; do
        # Reload after install/relocate/uninstall: each command runs in a child.
        INSTALL_ROOT='/opt/clouddrive2'
        if (( EUID == 0 )); then load_state; fi

        state='未安装'
        if [[ -f "$UNIT" ]]; then
            if service_running; then state='运行中'; else state='未运行'; fi
        fi
        installed_version="$(current_version)"
        # Run an automatic check once per installed version per menu session.
        # A successful query is cached for six hours across separate invocations.
        if [[ "$installed_version" != "$last_checked_version" ]]; then
            latest_seen=''
            if managed_install_present; then
                latest_seen="$(get_latest_release_cached 2>/dev/null)" || latest_seen=''
                update_notice="$(auto_update_notice "$installed_version" "$latest_seen")"
            elif [[ "$installed_version" == not-installed ]]; then
                update_notice='尚未安装（安装时会获取官方最新版本）'
            else
                update_notice='未检测到完整的脚本管理安装，请使用 4 查看状态'
            fi
            last_checked_version="$installed_version"
        fi
        printf '\n欢迎使用 CloudDrive2 管理脚本\n'
        printf '管理脚本：v%s | 核心：%s | 服务：%s\n' "$MANAGER_VERSION" "$installed_version" "$state"
        printf '程序目录：%s/current\n' "$INSTALL_ROOT"
        printf '配置目录：%s\n' "$DATA_DIR"
        printf '更新检测：%s\n' "$update_notice"
        if (( EUID != 0 )); then
            printf '提示：当前非 root 用户，请使用 sudo 运行以执行管理操作。\n'
        fi
        printf '\n'
        cat <<'EOF'
基础功能：
1、安装 CloudDrive2
2、更新 CloudDrive2
3、卸载 CloudDrive2
-------------------
服务管理：
4、查看状态
5、查看日志
6、启动 CloudDrive2
7、停止 CloudDrive2
8、重启 CloudDrive2
-------------------
配置管理：
9、备份配置
10、恢复配置
-------------------
高级选项：
11、版本管理
12、挂载与高级设置
13、系统状态
14、关于
-------------------
0、退出脚本

EOF
        printf '请输入选项 [0-14]: '
        IFS= read -r choice || { printf '\n'; return 0; }
        case "$choice" in
            1) menu_action install ;;
            2) menu_action update ;;
            3) menu_uninstall ;;
            4) menu_action status ;;
            5) menu_action logs-tail ;;
            6) menu_action start ;;
            7) menu_action stop ;;
            8) menu_action restart ;;
            9) menu_action backup ;;
           10) menu_restore ;;
           11) menu_version_management; last_checked_version='__unchecked__' ;;
           12) menu_advanced_management ;;
           13) show_system_info; menu_pause ;;
           14) show_about; menu_pause ;;
            0) printf '已退出 CloudDrive2 管理脚本。\n'; return 0 ;;
            *) warn '无效选项，请输入 0-14。'; menu_pause ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    if [[ "$cmd" == help || "$cmd" == --help || "$cmd" == -h ]]; then usage; return 0; fi
    # Display the menu even without root; only operational commands require
    # elevated permissions. This avoids a confusing initial permission error.
    if [[ "$cmd" == menu ]]; then menu; return 0; fi
    if [[ "$cmd" == about ]]; then
        if (( EUID == 0 )); then load_state; fi
        show_about
        return 0
    fi
    if [[ "$cmd" == system-info ]]; then
        if (( EUID == 0 )); then load_state; fi
        show_system_info
        return 0
    fi
    require_root
    load_state
    case "$cmd" in
        install|check|update|rollback|backup|restore) ensure_dependencies ;;
    esac
    acquire_lock
    case "$cmd" in
        install) do_install ;;
        check) do_check ;;
        update) do_update ;;
        rollback) do_rollback ;;
        version) current_version ;;
        status) show_status ;;
        start|stop|restart) check_managed && systemctl "$cmd" "$SERVICE" ;;
        logs) check_managed && journalctl -u "$SERVICE" -f ;;
        logs-tail) check_managed && journalctl -u "$SERVICE" -n 80 --no-pager ;;
        backup) do_backup ;;
        backups) show_backups ;;
        restore) do_restore "${2:-latest}" ;;
        enable-allow-other) enable_allow_other ;;
        relocate) [[ -n "${2:-}" ]] || { fail 'A target path is required.'; return 1; }; do_relocate "$2" ;;
        migrate-config) do_migrate_config ;;
        uninstall) do_uninstall "${2:-}" ;;
        *) usage; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
