#!/usr/bin/env bash
# An isolated loopback sshd; never reloads or edits the machine's SSH service.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source ./pd-ssh-tunnel.sh
[[ $EUID == 0 ]] || { echo 'Run integration test with sudo.'; exit 1; }
fixture=$(mktemp -d)
daemon=''
cleanup() {
    local rc=$?
    if (( rc != 0 )); then cat "$fixture/sshd.log" >&2; fi
    [[ -z "$daemon" ]] || { kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; }
    rm -rf -- "$fixture"
}
trap cleanup EXIT
APP_DIR="$fixture/app"
KEY_FILE="$APP_DIR/key"
PUB_KEY_FILE="$APP_DIR/key.pub"
KNOWN_HOSTS="$APP_DIR/known_hosts"
CONFIG_FILE="$APP_DIR/config"
FORWARDS_FILE="$APP_DIR/forwards.conf"
TUNNEL_USER=root
ensure_config_files
ensure_key
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
cp "$PUB_KEY_FILE" "$fixture/authorized_keys"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$fixture/sshd.conf" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/pid
AuthorizedKeysFile $fixture/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
# Fixture lives under /tmp, which can be writable on CI/VPS hosts.
StrictModes no
AllowUsers root
AllowTcpForwarding yes
PermitOpen 127.0.0.1:1
EOF
install -d -m 755 /run/sshd
/usr/sbin/sshd -t -f "$fixture/sshd.conf"
/usr/sbin/sshd -D -f "$fixture/sshd.conf" -E "$fixture/sshd.log" &
daemon=$!
sleep 1
ssh-keyscan -p "$port" 127.0.0.1 > "$KNOWN_HOSTS" 2>/dev/null
test_ssh_connection 127.0.0.1 "$port"
: > "$fixture/authorized_keys"
if test_ssh_connection 127.0.0.1 "$port"; then echo 'ERROR: empty authorized_keys accepted'; exit 1; fi
cp "$PUB_KEY_FILE" "$fixture/authorized_keys"
test_ssh_connection 127.0.0.1 "$port"
echo 'PASS: real SSH authentication, empty-key rejection and recovery'
