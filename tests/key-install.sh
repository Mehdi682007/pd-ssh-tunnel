#!/usr/bin/env bash
# Exercise the actual transmitted installer in a filesystem fixture.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source ./pd-ssh-tunnel.sh
[[ $EUID == 0 ]] || exit 1
fixture=$(mktemp -d)
export PD_FIXTURE="$fixture"
trap 'rm -rf -- "$fixture"' EXIT
APP_DIR="$fixture/source"; KEY_FILE="$APP_DIR/key"; PUB_KEY_FILE="$KEY_FILE.pub"
KNOWN_HOSTS="$APP_DIR/known_hosts"; CONFIG_FILE="$APP_DIR/config"; FORWARDS_FILE="$APP_DIR/forwards.conf"
TUNNEL_USER=root
ensure_config_files; ensure_key
mkdir -p "$fixture/destination/.ssh" "$fixture/state" "$fixture/sshd"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/other"
cp "$fixture/other.pub" "$fixture/destination/.ssh/authorized_keys"
printf 'old config\n' > "$fixture/sshd/90-reverse-tunnel.conf"
printf 'L|127.0.0.1:28888:127.0.0.1:28443\n' > "$FORWARDS_FILE"
getent() { printf 'root:x:0:0:root:%s/destination:/bin/bash\n' "$PD_FIXTURE"; }
systemctl() { return 0; }
sshd() { return 0; }
export -f getent systemctl sshd
ssh() {
    local arg command="${*: -1}"
    for arg in "$@"; do [[ "$arg" != -MNf && "$arg" != -O ]] || return 0; done
    command="${command//\/var\/lib\/pd-ssh-key-backup./$PD_FIXTURE/state/backup.}"
    # Translate only fixed installer paths, never evaluate fixture data as code.
    sed -e "s@/var/lib/pd-ssh-key-backup\.@$PD_FIXTURE/state/backup.@g" \
        -e "s@/etc/ssh/sshd_config.d@$PD_FIXTURE/sshd@g" \
        -e 's@/usr/sbin/sshd@sshd@g' |
        bash -c "$command" |
        sed "s@^PD_TRANSACTION=$PD_FIXTURE/state/backup.@PD_TRANSACTION=/var/lib/pd-ssh-key-backup.@"
}
test_ssh_connection() { return 0; }
install_key_automatically example.test 22 root
grep -q "$(awk '{print $2}' "$PUB_KEY_FILE")" "$fixture/destination/.ssh/authorized_keys"
grep -q "$(awk '{print $2}' "$fixture/other.pub")" "$fixture/destination/.ssh/authorized_keys"
grep -q 'PermitOpen 127.0.0.1:28443' "$fixture/sshd/90-reverse-tunnel.conf"
install_key_automatically example.test 22 root
[[ $(wc -l < "$fixture/destination/.ssh/authorized_keys") == 2 ]]
cp "$fixture/destination/.ssh/authorized_keys" "$fixture/before-keys"
cp "$fixture/sshd/90-reverse-tunnel.conf" "$fixture/before-dropin"
rm -f "$KEY_FILE" "$PUB_KEY_FILE"
ensure_key
test_ssh_connection() { return 1; }
if install_key_automatically example.test 22 root; then echo 'Failure incorrectly reported as success'; exit 1; fi
cmp "$fixture/before-keys" "$fixture/destination/.ssh/authorized_keys"
cmp "$fixture/before-dropin" "$fixture/sshd/90-reverse-tunnel.conf"
echo 'PASS: transmitted installer, previous keys, port allowlist, repeat installation, failed-auth rollback'
