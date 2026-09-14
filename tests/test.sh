#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source ./pd-ssh-tunnel.sh
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
APP_DIR="$fixture/app"
KEY_FILE="$APP_DIR/key"
PUB_KEY_FILE="$APP_DIR/key.pub"
CONFIG_FILE="$APP_DIR/config"
FORWARDS_FILE="$APP_DIR/forwards.conf"
KNOWN_HOSTS="$APP_DIR/known_hosts"
RUN_SCRIPT="$APP_DIR/run.sh"
ensure_config_files
validate_forward 'L|127.0.0.1:28888:127.0.0.1:28443'
validate_forward '0.0.0.0:7777:localhost:9999'
for bad in 'L|127.0.0.1:warning:localhost:22' 'Q|a:1:b:2' 'L|a:0:b:3' 'L|a:65536:b:1' 'L|a:99999999999999999999:b:1' 'L|a:1:b:2:3'; do
    if validate_forward "$bad"; then printf 'Incorrectly accepted %s\n' "$bad"; exit 1; fi
done
ensure_key
fingerprint=$(ssh-keygen -lf "$PUB_KEY_FILE")
printf 'broken\n' > "$PUB_KEY_FILE"
ensure_key
[[ "$(ssh-keygen -lf "$PUB_KEY_FILE")" == "$fingerprint" ]]
printf 'L|127.0.0.1:28888:localhost:28443\n' > "$FORWARDS_FILE"
forward_policy | grep -q 'PermitOpen localhost:28443'
forward_policy | grep -q 'PermitListen none'
export_settings "$fixture/export.txt"
printf 'R|127.0.0.1:7777:localhost:22\n' > "$FORWARDS_FILE"
import_settings "$fixture/export.txt"
grep -q '^L|' "$FORWARDS_FILE"
printf 'PD-SSH-SETTINGS-1\nL|invalid\n' > "$fixture/bad.txt"
if import_settings "$fixture/bad.txt"; then exit 1; fi
grep -q '^L|' "$FORWARDS_FILE"
set_config SERVER_HOST example.test
set_config SSH_PORT 22
set_config PERFORMANCE_MODE 1
build_run_script
bash -n "$RUN_SCRIPT"
# No service worker must never report healthy, even if systemd says active.
systemctl() { printf '0\n'; }
journalctl() { :; }
if health_check; then echo 'False healthy result'; exit 1; fi
unset -f systemctl journalctl
echo 'PASS: validation, key repair, allowlist, migration, runner syntax, failed health detection'
