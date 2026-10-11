#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT="$PWD/clouddrive2-manager.sh"

assert_contains() {
    local expected="$1" input="$2"
    [[ "$input" == *"$expected"* ]] || {
        printf 'Expected text was missing: %s\n' "$expected" >&2
        return 1
    }
}

# The menu must be visible even as an unprivileged user or when not installed.
start="$(printf '0\n' | bash "$SCRIPT")"
assert_contains '欢迎使用 CloudDrive2 管理脚本' "$start"
assert_contains '基础功能：' "$start"
assert_contains '服务管理：' "$start"
assert_contains '配置管理：' "$start"
assert_contains '高级选项：' "$start"
assert_contains '1、安装 CloudDrive2' "$start"
assert_contains '3、卸载 CloudDrive2' "$start"
assert_contains '请输入选项 [0-14]: ' "$start"
assert_contains '已退出 CloudDrive2 管理脚本。' "$start"

# Invalid inputs and EOF must not hang.
invalid="$(printf '99\n0\n' | bash "$SCRIPT" 2>&1)"
assert_contains '无效选项，请输入 0-14。' "$invalid"
timeout 5 bash "$SCRIPT" </dev/null >/dev/null

# Mock child-process dispatch to test every menu item without touching system.
source "$SCRIPT"
run_menu_command() { printf 'MOCK-EXEC:%s\n' "$*"; }
menu_pause() { :; }
load_state() { :; }
current_version() { printf 'mock-version\n'; }
service_running() { return 1; }
flow="$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nsample.tar.gz\ny\n11\n1\n2\n3\ny\n4\n0\n12\n1\n2\n/opt/example\n3\n0\n13\n14\n0\n' | menu)"
for command in install update uninstall status logs-tail start stop restart backup backups \
    'restore sample.tar.gz' check version rollback enable-allow-other 'relocate /opt/example'; do
    assert_contains "MOCK-EXEC:$command" "$flow"
done
assert_contains '系统状态：' "$flow"
assert_contains '关于 CloudDrive2 原生管理脚本' "$flow"
assert_contains '请输入选项 [0-4]: ' "$flow"
assert_contains '请输入选项 [0-3]: ' "$flow"


# Automatic release lookup, cached across menu sessions and refreshed after TTL.
temp_auto="$(mktemp -d)"
trap 'rm -rf -- "$temp_auto"' EXIT
UPDATE_CACHE_DIR="$temp_auto/updates"
UPDATE_CACHE_FILE="$UPDATE_CACHE_DIR/latest-release"
UPDATE_CACHE_TTL=21600
fetch_calls="$temp_auto/calls"
arch_name() { printf 'x86_64\n'; }
fetch_latest() {
    printf 'called\n' >> "$fetch_calls"
    printf '1.2.9\thttps://example.invalid/file\tsha256:placeholder\t123\n'
}
latest="$(get_latest_release_cached)"
[[ "$latest" == 1.2.9 ]]
assert_contains '发现新版本 1.2.3 → 1.2.9' "$(auto_update_notice 1.2.3 "$latest")"
assert_contains '已是最新版本' "$(auto_update_notice 1.2.9 "$latest")"
[[ "$(wc -l < "$fetch_calls")" == 1 ]]
[[ "$(get_latest_release_cached)" == 1.2.9 ]]
[[ "$(wc -l < "$fetch_calls")" == 1 ]]
touch -d '7 hours ago' "$UPDATE_CACHE_FILE"
[[ "$(get_latest_release_cached)" == 1.2.9 ]]
[[ "$(wc -l < "$fetch_calls")" == 2 ]]
assert_contains '本地不低于官方最新' "$(auto_update_notice 1.3.0 1.2.9)"

printf 'Menu and update-check tests passed.\n'
