#!/usr/bin/env bash
# Verify integrated/legacy layouts and safe uninstall/migration in a sandbox.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./clouddrive2-manager.sh

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
root="$work/opt/cd2"
mkdir -p "$work/opt" "$work/etc" "$work/mount"
INSTALL_ROOT="$root"
DATA_DIR="$root/config"
CONFIG_LAYOUT=integrated
LEGACY_DATA_DIR="$work/legacy-config"
BACKUP_DIR="$work/backups"
UPDATE_CACHE_DIR="$work/cache"
UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-release"
STATE="$work/etc/cd2-state.conf"
UNIT="$work/etc/clouddrive2.service"
MOUNT_DIR="$work/mount"
MANAGER_BIN="$work/bin/cd2-native"
SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"

# Only relax production's fixed /opt and /var guards within this temp sandbox.
valid_install_path() { [[ "$1" == "$work/opt/"* ]]; }
safe_legacy_config_path() { [[ "$LEGACY_DATA_DIR" == "$work/legacy-config" && ! -L "$LEGACY_DATA_DIR" ]]; }
safe_auxiliary_purge_paths() {
    [[ "$BACKUP_DIR" == "$work/backups" && "$UPDATE_CACHE_DIR" == "$work/cache" ]]
}
systemctl() {
    # No real systemd operation must take place in the integration test.
    if [[ "${1:-}" == list-unit-files ]]; then return 0; fi
    return 0
}
service_running() { return 1; }
wait_healthy() { return 0; }

assert() {
    if ! "$@"; then
        printf 'ASSERT FAILED: %s\n' "$*" >&2
        exit 1
    fi
}

# New installs always use the integrated config path.
load_state
assert test "$CONFIG_LAYOUT" = integrated
assert test "$DATA_DIR" = "$root/config"
mkdir -p "$root"
save_state
assert grep -qx 'CONFIG_LAYOUT=integrated' "$STATE"
INSTALL_ROOT="$work/opt/another"
load_state
assert test "$INSTALL_ROOT" = "$root"
assert test "$DATA_DIR" = "$root/config"

# Existing v1.x state has no layout field and MUST remain on the legacy path.
printf 'INSTALL_ROOT=%s\n' "$root" > "$STATE"
load_state
assert test "$CONFIG_LAYOUT" = legacy
assert test "$DATA_DIR" = "$LEGACY_DATA_DIR"

# The integration guard must reject a simulated nested mount.
mkdir -p "$root/releases/1.0.0" "$root/config" "$BACKUP_DIR" "$UPDATE_CACHE_DIR"
findmnt() { printf '/\n%s\n' "$root/mounted-cloud"; }
if assert_no_mounts_under "$root" >/dev/null 2>&1; then
    printf 'FAIL: nested mount guard was bypassed\n' >&2; exit 1
fi
unset -f findmnt
assert safe_install_root

# A legacy backup (archive prefix clouddrive2/) remains readable once config
# is moved to config/; the tar payload is written only inside the sandbox.
mkdir -p "$LEGACY_DATA_DIR"
printf 'old\n' > "$LEGACY_DATA_DIR/settings.txt"
legacy_backup="$BACKUP_DIR/old-config.tar.gz"
tar -czf "$legacy_backup" -C "$work" legacy-config >/dev/null
# Official legacy backup name is "clouddrive2", not the test-specific path.
mv "$LEGACY_DATA_DIR" "$work/clouddrive2"
tar -czf "$legacy_backup" -C "$work" clouddrive2
mv "$work/clouddrive2" "$LEGACY_DATA_DIR"
(cd "$BACKUP_DIR" && sha256sum old-config.tar.gz > old-config.tar.gz.sha256)
assert verify_backup "$legacy_backup"
# Purge intentionally deletes backup dir; retain a separate test fixture.
cp "$legacy_backup" "$work/legacy-fixture.tar.gz"
cp "$legacy_backup.sha256" "$work/legacy-fixture.sha256"

# A normal "keep data" uninstall removes only binaries + service files.
CONFIG_LAYOUT=integrated
set_config_dir
printf 'secret\n' > "$DATA_DIR/account.txt"
printf 'cloud-only\n' > "$MOUNT_DIR/remote-files-must-stay"
printf 'backup\n' > "$BACKUP_DIR/backup-marker"
printf 'cache\n' > "$UPDATE_CACHE_DIR/latest-release"
ln -s releases/1.0.0 "$root/current"
touch "$UNIT"
save_state
assert do_uninstall --yes
assert test -f "$DATA_DIR/account.txt"
assert test -f "$BACKUP_DIR/backup-marker"
assert test -f "$MOUNT_DIR/remote-files-must-stay"
assert test ! -e "$root/releases"
assert test ! -e "$STATE"

# Reinstall may reuse saved config (rather than refusing nonempty install root).
# Avoid false collision from unrelated listeners on the host.
ss() { :; }
assert check_conflicts
unset -f ss

# A full purge requires exact typed confirmation; bad input changes nothing.
mkdir -p "$root/releases/1.0.0"
ln -s releases/1.0.0 "$root/current"
touch "$UNIT"
save_state
printf 'wrong\n' | do_uninstall --purge
assert test -f "$DATA_DIR/account.txt"
assert test -f "$STATE"

# Destructive purge deletes managed *local* paths, NEVER remote/mount content.
printf 'DELETE-ALL-LOCAL-DATA\n' | do_uninstall --purge
assert test ! -e "$root"
assert test ! -e "$BACKUP_DIR"
assert test ! -e "$UPDATE_CACHE_DIR"
assert test ! -e "$STATE"
assert test -f "$MOUNT_DIR/remote-files-must-stay"

# Legacy layout migration: backup, copy, new systemd CLOUDDRIVE_HOME, keep
# prior stopped state, remove old after successful healthy service check.
mkdir -p "$root/releases/1.0.0" "$LEGACY_DATA_DIR" "$BACKUP_DIR"
cp "$work/legacy-fixture.tar.gz" "$legacy_backup"
cp "$work/legacy-fixture.sha256" "$legacy_backup.sha256"
ln -s releases/1.0.0 "$root/current"
printf 'legacy-account\n' > "$LEGACY_DATA_DIR/account.txt"
CONFIG_LAYOUT=legacy
set_config_dir
touch "$UNIT"
save_state
assert do_migrate_config
assert test "$CONFIG_LAYOUT" = integrated
assert test "$DATA_DIR" = "$root/config"
assert test -f "$DATA_DIR/account.txt"
assert test ! -e "$LEGACY_DATA_DIR"
assert grep -Fq "Environment=CLOUDDRIVE_HOME=$DATA_DIR" "$UNIT"
assert grep -qx 'CONFIG_LAYOUT=integrated' "$STATE"
assert test "$(find "$BACKUP_DIR" -maxdepth 1 -name 'pre-config-migration*.tar.gz' | wc -l)" -eq 1

# Old-format backup recovery even after moving to config/.
assert restore_data_from_backup "$legacy_backup"
assert test -f "$root/config/settings.txt"
assert test -f "$MOUNT_DIR/remote-files-must-stay"

printf 'Layout, backup compatibility, keep/purge uninstall, migration tests passed.\n'
