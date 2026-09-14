#!/usr/bin/env bash
set -Eeuo pipefail

# SSH Tunnel Manager (Local and Reverse forwards)
# Production-oriented interactive manager for Ubuntu/Debian + systemd.
#
# Same script:
#   IR Iran/source server
#   🌍 Foreign/destination server
#
# Features:
#   - Interactive role selection
#   - Automatic foreign-server setup
#   - Ed25519 SSH authentication
#   - Dedicated nologin tunnel user
#   - autossh + systemd
#   - Add/remove multiple reverse forwards
#   - Strict SSH host-key checking
#   - SSH connection testing
#   - Local service testing
#   - Tunnel status and logs
#   - Configuration backup
#   - Safe uninstall
#
# No passwords or private keys are embedded in this file.
#
# Configuration:
#   /etc/reverse-ssh-tunnel/
#
# Service:
#   reverse-ssh-tunnel.service

APP_DIR="/etc/reverse-ssh-tunnel"
KEY_FILE="$APP_DIR/id_ed25519"
PUB_KEY_FILE="$APP_DIR/id_ed25519.pub"
KNOWN_HOSTS="$APP_DIR/known_hosts"
CONFIG_FILE="$APP_DIR/config"
FORWARDS_FILE="$APP_DIR/forwards.conf"
RUN_SCRIPT="$APP_DIR/run.sh"

UNIT_NAME="reverse-ssh-tunnel.service"
TUNNEL_USER="revtunnel"
TUNNEL_MARKER="/var/lib/reverse-ssh-tunnel-manager-created"

SSHD_DROPIN="/etc/ssh/sshd_config.d/90-reverse-tunnel.conf"
PERF_SYSCTL="/etc/sysctl.d/99-pd-ssh-tunnel-performance.conf"
PERF_STATE="/var/lib/reverse-ssh-tunnel-performance.before"

VERSION="1.4.0"

# ---------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------

RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'

# ---------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------

die() {
    echo
    echo "${RED}✖ ERROR:${RESET} $*" >&2
    exit 1
}

info() {
    echo "${BLUE}ℹ${RESET} $*"
}

ok() {
    echo "${GREEN}✔${RESET} $*"
}

warn() {
    # Warnings must never be captured as return values by helpers that are
    # called through command substitution (for example read_port).
    echo "${YELLOW}⚠${RESET} $*" >&2
}

clear_screen() {
    clear 2>/dev/null || printf '\033c'
}

pause_screen() {
    echo
    read -r -p "Press Enter to continue..." _
}

header() {
    clear_screen

    echo
    echo "${MAGENTA}${BOLD} _______  ______              _______  _______  __   __    _______  __   __  __    _  __    _  _______  ___${RESET}"
    echo "${MAGENTA}${BOLD}|       ||      |            |       ||       ||  | |  |  |       ||  | |  ||  |  | ||  |  | ||       ||   |${RESET}"
    echo "${CYAN}${BOLD}|    _  ||  _    |   ____    |  _____||  _____||  |_|  |  |_     _||  | |  ||   |_| ||   |_| ||    ___||   |${RESET}"
    echo "${CYAN}${BOLD}|   |_| || | |   |  |____|   | |_____ | |_____ |       |    |   |  |  |_|  ||       ||       ||   |___ |   |${RESET}"
    echo "${CYAN}${BOLD}|    ___|| |_|   |           |_____  ||_____  ||       |    |   |  |       ||  _    ||  _    ||    ___||   |___${RESET}"
    echo "${MAGENTA}${BOLD}|   |    |       |            _____| | _____| ||   _   |    |   |  |       || | |   || | |   ||   |___ |       |${RESET}"
    echo "${MAGENTA}${BOLD}|___|    |______|            |_______||_______||__| |__|    |___|  |_______||_|  |__||_|  |__||_______||_______|${RESET}"
    echo
    echo "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}${BOLD}║                 🔐 SSH Tunnel Manager                    ║${RESET}"
    echo "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo "${DIM}Version $VERSION${RESET}"
    echo
}

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] ||
        die "Run this script as root or with sudo."
}

detect_os() {
    [[ -r /etc/os-release ]] ||
        die "Cannot identify the operating system."

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            ;;
        *)
            die "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu and Debian are supported."
            ;;
    esac
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    apt-get install -y --no-install-recommends "$@"
}

ensure_dirs() {
    install -d -m 700 "$APP_DIR"
}

ensure_config_files() {
    ensure_dirs

    touch "$CONFIG_FILE"
    touch "$FORWARDS_FILE"

    chmod 600 "$CONFIG_FILE"
    chmod 600 "$FORWARDS_FILE"
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_bind() {
    [[ "$1" =~ ^[A-Za-z0-9.:_-]+$ ]]
}

# ---------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------

read_port() {
    local prompt="$1"
    local value

    while :; do
        read -r -p "$prompt" value

        if valid_port "$value"; then
            printf '%s' "$value"
            return
        fi

        warn "Enter a valid TCP port from 1 to 65535."
    done
}

read_port_default() {
    local prompt="$1"
    local default="$2"
    local value

    while :; do
        read -r -p "$prompt" value
        value="${value:-$default}"

        if valid_port "$value"; then
            printf '%s' "$value"
            return
        fi

        warn "Enter a valid TCP port from 1 to 65535."
    done
}

read_yes_no() {
    local prompt="$1"
    local answer

    while :; do
        read -r -p "$prompt [y/n]: " answer

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                warn "Please answer y or n."
                ;;
        esac
    done
}

read_menu_choice() {
    local prompt="$1"
    local max="$2"
    local choice

    while :; do
        read -r -p "$prompt" choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 0 && choice <= max )); then
            printf '%s' "$choice"
            return
        fi

        warn "Invalid selection."
    done
}

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

set_config() {
    local key="$1"
    local value="$2"
    local tmp

    ensure_config_files

    tmp=$(mktemp)

    awk -v k="$key" -v v="$value" '
        BEGIN { found=0 }

        $0 ~ "^" k "=" {
            if (!found) {
                print k "=" v
                found=1
            }
            next
        }

        { print }

        END {
            if (!found)
                print k "=" v
        }
    ' "$CONFIG_FILE" > "$tmp"

    mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

get_config() {
    local key="$1"

    [[ -f "$CONFIG_FILE" ]] || return 0

    sed -n "s/^${key}=//p" "$CONFIG_FILE" | tail -n1
}

# ---------------------------------------------------------------------
# SSH key management
# ---------------------------------------------------------------------

ensure_key() {
    ensure_dirs

    install_packages openssh-client autossh ca-certificates

    if [[ ! -f "$KEY_FILE" ]]; then
        info "Generating an Ed25519 SSH key..."

        ssh-keygen \
            -q \
            -t ed25519 \
            -N '' \
            -C reverse-ssh-tunnel \
            -f "$KEY_FILE"

        ok "SSH key generated."
    else
        ok "Existing SSH key found."
    fi

    if [[ ! -f "$PUB_KEY_FILE" ]]; then
        ssh-keygen -y \
            -f "$KEY_FILE" \
            > "$PUB_KEY_FILE"
    fi

    chmod 600 "$KEY_FILE"
    chmod 644 "$PUB_KEY_FILE"
}

show_public_key() {
    ensure_key

    echo
    echo "${BOLD}🔑 Public key${RESET}"
    echo "${DIM}Copy the complete line when manual installation is required.${RESET}"
    echo

    echo "────────────────────────────────────────────────────────────"

    cat "$PUB_KEY_FILE"

    echo "────────────────────────────────────────────────────────────"
}

# ---------------------------------------------------------------------
# SSH host-key handling
# ---------------------------------------------------------------------

safe_ssh_keyscan() {
    local host="$1"
    local port="$2"
    local tmp
    local new_fingerprint=""
    local old_fingerprint=""

    ensure_dirs

    tmp="$KNOWN_HOSTS.new"

    rm -f "$tmp"

    if ! timeout 15 \
        ssh-keyscan \
        -T 10 \
        -p "$port" \
        -H "$host" \
        > "$tmp" 2>/dev/null; then

        rm -f "$tmp"
        return 1
    fi

    [[ -s "$tmp" ]] ||
        return 1

    new_fingerprint=$(
        ssh-keygen -lf "$tmp" 2>/dev/null |
        head -n1 || true
    )

    if [[ -f "$KNOWN_HOSTS" ]]; then
        old_fingerprint=$(
            ssh-keygen -lf "$KNOWN_HOSTS" 2>/dev/null |
            head -n1 || true
        )

        if [[ -n "$old_fingerprint" &&
              -n "$new_fingerprint" &&
              "$old_fingerprint" != "$new_fingerprint" ]]; then

            echo
            warn "SSH host key changed."

            echo
            echo "Previous:"
            echo "  $old_fingerprint"

            echo
            echo "Current:"
            echo "  $new_fingerprint"

            echo

            if ! read_yes_no "Trust the new SSH host key?"; then
                rm -f "$tmp"
                return 1
            fi

            cp -a \
                "$KNOWN_HOSTS" \
                "$KNOWN_HOSTS.bak.$(date +%s)"
        fi
    else
        echo
        echo "SSH host fingerprint:"
        echo "  ${CYAN}${new_fingerprint:-unknown}${RESET}"
        echo

        if ! read_yes_no "Trust this SSH host key?"; then
            rm -f "$tmp"
            return 1
        fi
    fi

    mv "$tmp" "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    return 0
}

# ---------------------------------------------------------------------
# Foreign server configuration
# ---------------------------------------------------------------------

configure_foreign_ssh() {
    install_packages openssh-server

    if ! id "$TUNNEL_USER" >/dev/null 2>&1; then

        useradd \
            --create-home \
            --shell /usr/sbin/nologin \
            "$TUNNEL_USER"

        install -d -m 700 "$(dirname "$TUNNEL_MARKER")"

        touch "$TUNNEL_MARKER"

        ok "Created dedicated tunnel user: $TUNNEL_USER"

    else
        ok "Tunnel user already exists: $TUNNEL_USER"
    fi

    local home_dir

    home_dir=$(
        getent passwd "$TUNNEL_USER" |
        cut -d: -f6
    )

    [[ -n "$home_dir" ]] ||
        die "Could not determine $TUNNEL_USER home directory."

    install -d \
        -o "$TUNNEL_USER" \
        -g "$TUNNEL_USER" \
        -m 700 \
        "$home_dir/.ssh"

    touch "$home_dir/.ssh/authorized_keys"

    chown \
        "$TUNNEL_USER:$TUNNEL_USER" \
        "$home_dir/.ssh/authorized_keys"

    chmod 600 \
        "$home_dir/.ssh/authorized_keys"

    cat > "$SSHD_DROPIN" <<EOF
# Managed by reverse-ssh-tunnel-manager.sh

Match User $TUNNEL_USER
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowTcpForwarding yes
    GatewayPorts clientspecified
EOF

    chmod 644 "$SSHD_DROPIN"

    # Some minimal VPS images do not create sshd's volatile runtime directory
    # until the service starts. sshd -t still requires it to exist.
    install -d -o root -g root -m 0755 /run/sshd

    sshd -t ||
        die "sshd configuration test failed. SSH was NOT reloaded."

    if systemctl reload ssh 2>/dev/null; then
        :
    elif systemctl reload sshd 2>/dev/null; then
        :
    else
        systemctl restart ssh 2>/dev/null ||
            systemctl restart sshd
    fi

    ok "SSH server configured for reverse tunneling."
}

install_public_key_for_tunnel_user() {
    local pubkey="$1"

    local home_dir
    local key_file
    local candidate
    local backup=""

    key_file=$(mktemp)
    printf '%s\n' "$pubkey" > "$key_file"

    if ! ssh-keygen -lf "$key_file" >/dev/null 2>&1; then
        rm -f "$key_file"
        die "Invalid or damaged SSH public key. Nothing was changed."
    fi

    rm -f "$key_file"

    home_dir=$(
        getent passwd "$TUNNEL_USER" |
        cut -d: -f6
    )

    [[ -n "$home_dir" ]] ||
        die "Could not determine tunnel user home directory."

    install -d \
        -o "$TUNNEL_USER" \
        -g "$TUNNEL_USER" \
        -m 700 \
        "$home_dir/.ssh"

    touch "$home_dir/.ssh/authorized_keys"

    if [[ -s "$home_dir/.ssh/authorized_keys" ]]; then
        backup="$home_dir/.ssh/authorized_keys.bak.$(date +%s)"
        cp -a "$home_dir/.ssh/authorized_keys" "$backup"
    fi

    if grep -qxF "$pubkey" \
        "$home_dir/.ssh/authorized_keys"; then

        ok "Public key is already installed."

    else

        candidate=$(mktemp "$home_dir/.ssh/authorized_keys.new.XXXXXX")

        if [[ -s "$home_dir/.ssh/authorized_keys" ]]; then
            cat "$home_dir/.ssh/authorized_keys" > "$candidate"
        fi

        printf '%s\n' "$pubkey" >> "$candidate"

        if ! ssh-keygen -lf "$candidate" >/dev/null 2>&1; then
            rm -f "$candidate"

            if [[ -n "$backup" && -f "$backup" ]]; then
                cp -a "$backup" "$home_dir/.ssh/authorized_keys"
            fi

            die "Public-key verification failed. The previous file was preserved."
        fi

        chown "$TUNNEL_USER:$TUNNEL_USER" "$candidate"
        chmod 600 "$candidate"
        mv -f "$candidate" "$home_dir/.ssh/authorized_keys"

        ok "Public key installed for $TUNNEL_USER."
    fi

    chown \
        "$TUNNEL_USER:$TUNNEL_USER" \
        "$home_dir/.ssh/authorized_keys"

    chmod 600 \
        "$home_dir/.ssh/authorized_keys"

    ssh-keygen -lf "$home_dir/.ssh/authorized_keys" >/dev/null 2>&1 ||
        die "authorized_keys verification failed."
}

foreign_setup() {
    header

    echo "${BOLD}🛠️  Foreign Server Initial Setup${RESET}"
    echo

    info "Installing OpenSSH server..."
    configure_foreign_ssh

    echo
    ok "Foreign server is ready."

    echo
    echo "Tunnel user:"
    echo "  ${CYAN}$TUNNEL_USER${RESET}"

    echo
    echo "Next step:"
    echo "  🔑 Install Iran public key"
}

foreign_add_key() {
    header

    echo "${BOLD}🔑 Install Iran Server Public Key${RESET}"
    echo

    if ! id "$TUNNEL_USER" >/dev/null 2>&1; then

        warn "Tunnel user does not exist."

        echo
        echo "Run ${BOLD}🛠️ Initial setup${RESET} first."

        return 1
    fi

    echo "Paste the complete public key."
    echo "It should normally start with ${CYAN}ssh-ed25519${RESET}."
    echo

    local pubkey

    read -r -p "Public key: " pubkey

    [[ "$pubkey" == ssh-ed25519\ * ||
       "$pubkey" == ssh-rsa\ * ]] ||
        die "Invalid SSH public key."

    install_public_key_for_tunnel_user "$pubkey"

    if [[ ! -f "$SSHD_DROPIN" ]]; then
        configure_foreign_ssh
    fi
}

foreign_status() {
    header

    echo "${BOLD}📊 Foreign Server Status${RESET}"
    echo

    if id "$TUNNEL_USER" >/dev/null 2>&1; then
        ok "Tunnel user: $TUNNEL_USER"
    else
        warn "Tunnel user: not installed"
    fi

    if [[ -f "$SSHD_DROPIN" ]]; then
        ok "Reverse SSH configuration: installed"
    else
        warn "Reverse SSH configuration: not installed"
    fi

    local home_dir

    home_dir=$(
        getent passwd "$TUNNEL_USER" 2>/dev/null |
        cut -d: -f6 || true
    )

    if [[ -n "$home_dir" &&
          -f "$home_dir/.ssh/authorized_keys" ]]; then

        local count

        count=$(
            grep -cE \
            '^(ssh-ed25519|ssh-rsa) ' \
            "$home_dir/.ssh/authorized_keys" \
            2>/dev/null || true
        )

        echo "🔑 Authorized tunnel keys: $count"

    else
        echo "🔑 Authorized tunnel keys: 0"
    fi

    echo
    echo "${BOLD}🌐 Listening TCP sockets${RESET}"
    echo

    ss -lnt 2>/dev/null || true
}

foreign_list_keys() {
    header

    echo "${BOLD}🔑 Authorized Tunnel Keys${RESET}"
    echo

    local home_dir

    home_dir=$(
        getent passwd "$TUNNEL_USER" 2>/dev/null |
        cut -d: -f6 || true
    )

    if [[ -z "$home_dir" ||
          ! -f "$home_dir/.ssh/authorized_keys" ]]; then

        warn "No authorized keys found."
        return
    fi

    nl -ba "$home_dir/.ssh/authorized_keys"
}

foreign_remove_keys() {
    header

    echo "${BOLD}🗑️  Remove Authorized Tunnel Keys${RESET}"
    echo

    local home_dir

    home_dir=$(
        getent passwd "$TUNNEL_USER" 2>/dev/null |
        cut -d: -f6 || true
    )

    [[ -n "$home_dir" &&
       -f "$home_dir/.ssh/authorized_keys" ]] ||
        die "No authorized_keys file found."

    warn "This removes ALL public keys for $TUNNEL_USER."

    if ! read_yes_no "Continue?"; then
        return
    fi

    : > "$home_dir/.ssh/authorized_keys"

    chown \
        "$TUNNEL_USER:$TUNNEL_USER" \
        "$home_dir/.ssh/authorized_keys"

    chmod 600 \
        "$home_dir/.ssh/authorized_keys"

    ok "All tunnel authorized keys removed."
}

foreign_uninstall() {
    header

    echo "${BOLD}🗑️  Uninstall Foreign Configuration${RESET}"
    echo

    warn "This removes the SSH configuration managed by this script."

    if [[ -f "$TUNNEL_MARKER" ]]; then
        warn "The tunnel user was created by this manager."
    else
        warn "The tunnel user may have existed before this manager."
        warn "It will NOT be deleted automatically."
    fi

    echo

    if ! read_yes_no "Continue?"; then
        return
    fi

    rm -f "$SSHD_DROPIN"

    install -d -o root -g root -m 0755 /run/sshd

    if sshd -t; then

        if systemctl reload ssh 2>/dev/null; then
            :
        elif systemctl reload sshd 2>/dev/null; then
            :
        else
            systemctl restart ssh 2>/dev/null ||
                systemctl restart sshd
        fi

    else
        warn "sshd configuration test failed."
        warn "Review SSH configuration before restarting SSH."
    fi

    if [[ -f "$TUNNEL_MARKER" ]] &&
       id "$TUNNEL_USER" >/dev/null 2>&1; then

        userdel -r "$TUNNEL_USER" 2>/dev/null ||
            userdel "$TUNNEL_USER"

        rm -f "$TUNNEL_MARKER"

        ok "Tunnel user removed."

    else
        warn "Tunnel user was preserved."
    fi

    ok "Foreign-side configuration removed."
}

# ---------------------------------------------------------------------
# Automatic key installation
# ---------------------------------------------------------------------

install_key_automatically() {
    local server="$1"
    local ssh_port="$2"
    local admin_user="$3"

    install_packages openssh-client

    echo
    info "Connecting to the foreign server as $admin_user..."
    echo
    echo "The administrative SSH password may be requested."
    echo "It is NOT stored by this script."
    echo

    local pubkey
    local pubkey_b64

    pubkey=$(cat "$PUB_KEY_FILE")
    pubkey_b64=$(printf '%s' "$pubkey" | base64 -w 0)

    info "Configuring the dedicated tunnel account..."

    if ! ssh \
        -p "$ssh_port" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        "$admin_user@$server" \
        "TUNNEL_USER='$TUNNEL_USER' PUBKEY_B64='$pubkey_b64' bash -s" <<'REMOTE'
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "The administrative SSH account must have root privileges." >&2
    exit 1
fi

PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)"
KEY_CHECK="$(mktemp)"
printf '%s\n' "$PUBKEY" > "$KEY_CHECK"

if ! ssh-keygen -lf "$KEY_CHECK" >/dev/null 2>&1; then
    rm -f "$KEY_CHECK"
    echo "Received public key is invalid or damaged." >&2
    exit 1
fi

rm -f "$KEY_CHECK"

if ! command -v sshd >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y --no-install-recommends openssh-server
fi

if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd \
        --create-home \
        --shell /usr/sbin/nologin \
        "$TUNNEL_USER"
fi

HOME_DIR="$(getent passwd "$TUNNEL_USER" | cut -d: -f6)"

if [[ -z "$HOME_DIR" ]]; then
    echo "Could not determine tunnel user home directory." >&2
    exit 1
fi

install -d \
    -o "$TUNNEL_USER" \
    -g "$TUNNEL_USER" \
    -m 700 \
    "$HOME_DIR/.ssh"

AUTHORIZED_KEYS="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTHORIZED_KEYS"

BACKUP=""

if [[ -s "$AUTHORIZED_KEYS" ]]; then
    BACKUP="$AUTHORIZED_KEYS.bak.$(date +%s)"
    cp -a "$AUTHORIZED_KEYS" "$BACKUP"
fi

if ! grep -qxF "$PUBKEY" \
    "$AUTHORIZED_KEYS"; then

    CANDIDATE="$(mktemp "$HOME_DIR/.ssh/authorized_keys.new.XXXXXX")"

    if [[ -s "$AUTHORIZED_KEYS" ]]; then
        cat "$AUTHORIZED_KEYS" > "$CANDIDATE"
    fi

    printf '%s\n' "$PUBKEY" >> "$CANDIDATE"

    if ! ssh-keygen -lf "$CANDIDATE" >/dev/null 2>&1; then
        rm -f "$CANDIDATE"

        if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
            cp -a "$BACKUP" "$AUTHORIZED_KEYS"
        fi

        echo "New authorized_keys failed verification; previous file preserved." >&2
        exit 1
    fi

    chown "$TUNNEL_USER:$TUNNEL_USER" "$CANDIDATE"
    chmod 600 "$CANDIDATE"
    mv -f "$CANDIDATE" "$AUTHORIZED_KEYS"
fi

chown \
    "$TUNNEL_USER:$TUNNEL_USER" \
    "$AUTHORIZED_KEYS"

chmod 600 \
    "$AUTHORIZED_KEYS"

ssh-keygen -lf "$AUTHORIZED_KEYS" >/dev/null 2>&1 || {
    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        cp -a "$BACKUP" "$AUTHORIZED_KEYS"
        chown "$TUNNEL_USER:$TUNNEL_USER" "$AUTHORIZED_KEYS"
        chmod 600 "$AUTHORIZED_KEYS"
    fi

    echo "authorized_keys verification failed." >&2
    exit 1
}

SSH_DROPIN="/etc/ssh/sshd_config.d/90-reverse-tunnel.conf"

cat > "$SSH_DROPIN" <<EOF
# Managed by reverse-ssh-tunnel-manager.sh

Match User $TUNNEL_USER
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowTcpForwarding yes
    GatewayPorts clientspecified
EOF

chmod 644 "$SSH_DROPIN"

install -d -o root -g root -m 0755 /run/sshd

sshd -t

if systemctl reload ssh 2>/dev/null; then
    :
elif systemctl reload sshd 2>/dev/null; then
    :
else
    systemctl restart ssh 2>/dev/null ||
        systemctl restart sshd
fi
REMOTE
    then

        ok "Foreign server configured automatically."

    else

        warn "Automatic foreign-server configuration failed."
        return 1
    fi

    echo
    info "Testing tunnel-user SSH authentication..."

    if test_ssh_connection "$server" "$ssh_port"; then
        ok "SSH authentication successful."
        return 0
    fi

    warn "SSH authentication failed."
    return 1
}

# ---------------------------------------------------------------------
# SSH connection test
# ---------------------------------------------------------------------

test_ssh_connection() {
    local server="${1:-$(get_config SERVER_HOST)}"
    local ssh_port="${2:-$(get_config SSH_PORT)}"

    ssh_port="${ssh_port:-22}"

    [[ -n "$server" ]] ||
        return 1

    ensure_key

    [[ -s "$KNOWN_HOSTS" ]] ||
        return 1

    info "Testing SSH authentication to $TUNNEL_USER@$server:$ssh_port..."

    # The tunnel user intentionally has /usr/sbin/nologin.
    # Therefore we test authentication by opening a session without
    # requiring an interactive shell. The expected nologin message
    # still means public-key authentication succeeded.
    local output=""
    local rc=0

    output=$(
        ssh \
            -p "$ssh_port" \
            -i "$KEY_FILE" \
            -o BatchMode=yes \
            -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$KNOWN_HOSTS" \
            "$TUNNEL_USER@$server" \
            2>&1
    ) || rc=$?

    if grep -q \
        "This account is currently not available" \
        <<< "$output"; then

        ok "SSH public-key authentication successful."
        return 0
    fi

    if [[ "$rc" -eq 0 ]]; then
        ok "SSH authentication successful."
        return 0
    fi

    if grep -qiE \
        "Permission denied|No supported authentication methods" \
        <<< "$output"; then

        warn "SSH authentication failed."
        echo "$output"

        return 1
    fi

    warn "SSH test returned an unexpected result."
    echo "$output"

    return 1
}

# ---------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------

get_forward_entries() {
    [[ -f "$FORWARDS_FILE" ]] || return 0

    grep -vE \
        '^[[:space:]]*(#|$)' \
        "$FORWARDS_FILE" || true
}

foreign_port_available() {
    local bind="$1"
    local port="$2"

    if [[ "$bind" == "0.0.0.0" ||
          "$bind" == "*" ]]; then

        ! ss -lntH 2>/dev/null |
            awk -v p=":$port" '$4 ~ p"$" { found=1 } END { exit found }'

        return
    fi

    ! ss -lntH 2>/dev/null |
        awk -v endpoint="$bind:$port" \
            '$4 == endpoint { found=1 } END { exit found }'
}

add_forward() {
    ensure_config_files

    header

    echo "${BOLD}➕ Add Port Forward${RESET}"
    echo
    echo "  1) 🇩🇪 Germany egress: Local forward (-L)"
    echo "     Iran local port → SSH → Germany service"
    echo "  2) IR Iran egress: Reverse forward (-R)"
    echo "     Germany port → SSH → Iran service"
    echo "  0) Cancel"
    echo

    local direction
    direction=$(read_menu_choice "Select direction: " 2)
    (( direction == 0 )) && return

    local bind_host
    local bind_port
    local target_host
    local target_port
    local prefix
    local line

    if (( direction == 1 )); then
        prefix="L"
        read -r -p "IR Iran bind address [127.0.0.1]: " bind_host
        bind_host="${bind_host:-127.0.0.1}"
        bind_port=$(read_port "IR Iran local tunnel port [example 28888]: ")
        read -r -p "🇩🇪 Germany target host [127.0.0.1]: " target_host
        target_host="${target_host:-127.0.0.1}"
        target_port=$(read_port "🇩🇪 Germany 3x-ui inbound port: ")
    else
        prefix="R"
        read -r -p "🌍 Foreign bind address [127.0.0.1]: " bind_host
        bind_host="${bind_host:-127.0.0.1}"
        bind_port=$(read_port "🌍 Foreign tunnel port: ")
        read -r -p "IR Iran target host [127.0.0.1]: " target_host
        target_host="${target_host:-127.0.0.1}"
        target_port=$(read_port "IR Iran service port: ")
    fi

    valid_bind "$bind_host" || die "Invalid bind address."
    valid_host "$target_host" || die "Invalid target host."

    line="$prefix|$bind_host:$bind_port:$target_host:$target_port"

    if grep -qxF "$line" "$FORWARDS_FILE" 2>/dev/null; then
        warn "This exact forward already exists."
        return
    fi

    printf '%s\n' "$line" >> "$FORWARDS_FILE"

    chmod 600 "$FORWARDS_FILE"

    if [[ "$prefix" == "L" ]]; then
        ok "Germany-egress local forward added:"
        echo "   IR $bind_host:$bind_port → SSH → 🇩🇪 $target_host:$target_port"
    else
        ok "Iran-egress reverse forward added:"
        echo "   🌍 $bind_host:$bind_port → SSH → IR $target_host:$target_port"
    fi

    echo

    if read_yes_no "Restart the tunnel now?"; then
        restart_tunnel
    fi
}

list_forwards() {
    ensure_config_files

    header

    echo "${BOLD}📋 Configured Port Forwards${RESET}"
    echo

    local entries=()

    mapfile -t entries < <(
        get_forward_entries
    )

    if (( ${#entries[@]} == 0 )); then
        echo "No port forwards configured."
        return
    fi

    local i=0
    local line
    local rb
    local rp
    local lh
    local lp
    local extra
    local mode
    local spec

    for line in "${entries[@]}"; do

        if [[ "$line" == *"|"* ]]; then
            mode="${line%%|*}"
            spec="${line#*|}"
        else
            mode="R"
            spec="$line"
        fi

        IFS=: read -r \
            rb rp lh lp extra \
            <<< "$spec"

        i=$((i + 1))

        if [[ "$mode" == "L" ]]; then
            printf "  ${CYAN}%2d${RESET}) [L/Germany egress] IR %s:%s → 🇩🇪 %s:%s\n" \
                "$i" "$rb" "$rp" "$lh" "$lp"
        else
            printf "  ${CYAN}%2d${RESET}) [R/Iran egress] 🌍 %s:%s → IR %s:%s\n" \
                "$i" "$rb" "$rp" "$lh" "$lp"
        fi
    done
}

remove_forward() {
    ensure_config_files

    local entries=()

    mapfile -t entries < <(
        get_forward_entries
    )

    header

    echo "${BOLD}➖ Remove Port Forward${RESET}"
    echo

    if (( ${#entries[@]} == 0 )); then
        echo "No port forwards configured."
        return
    fi

    local i=0
    local line

    for line in "${entries[@]}"; do
        i=$((i + 1))
        echo "  $i) $line"
    done

    echo "  0) Cancel"
    echo

    local n

    n=$(read_menu_choice \
        "Select a forward: " \
        "${#entries[@]}")

    (( n == 0 )) && return

    local selected="${entries[$((n - 1))]}"

    echo
    echo "Selected: $selected"

    if ! read_yes_no "Remove this forward?"; then
        return
    fi

    local tmp

    tmp=$(mktemp)

    awk \
        -v target="$selected" \
        '$0 != target {
            print
        }' \
        "$FORWARDS_FILE" > "$tmp"

    mv "$tmp" "$FORWARDS_FILE"

    chmod 600 "$FORWARDS_FILE"

    ok "Forward removed."

    if read_yes_no "Restart the tunnel now?"; then
        restart_tunnel
    fi
}

# ---------------------------------------------------------------------
# Systemd / autossh
# ---------------------------------------------------------------------

performance_status() {
    header
    echo "${BOLD}🚀 SSH Tunnel Performance Status${RESET}"
    echo

    if [[ -f "$PERF_SYSCTL" ]]; then
        ok "Kernel performance profile: enabled"
    else
        warn "Kernel performance profile: disabled"
    fi

    if [[ "$(get_config PERFORMANCE_MODE)" == "1" ]]; then
        ok "Optimized SSH options: enabled"
    else
        warn "Optimized SSH options: disabled"
    fi

    echo
    printf 'Congestion control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf 'Queue discipline:  %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    printf 'MTU probing:       %s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unknown)"
    printf 'Receive max:       %s bytes\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
    printf 'Send max:          %s bytes\n' "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
}

save_performance_state() {
    [[ -f "$PERF_STATE" ]] && return 0

    install -d -m 700 "$(dirname "$PERF_STATE")"

    local key
    : > "$PERF_STATE"

    for key in \
        net.core.default_qdisc \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem; do

        if sysctl -n "$key" >/dev/null 2>&1; then
            printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$PERF_STATE"
        fi
    done

    chmod 600 "$PERF_STATE"
}

enable_performance_profile() {
    need_root
    ensure_config_files
    save_performance_state

    modprobe tcp_bbr 2>/dev/null || true

    cat > "$PERF_SYSCTL" <<'EOF'
# Managed by PD - SSH Tunnle
# Conservative throughput profile for persistent SSH forwarding.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    chmod 644 "$PERF_SYSCTL"
    sysctl --system >/dev/null

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
        die "BBR could not be enabled on this kernel."
    fi

    if ! ssh -Q cipher 2>/dev/null | grep -qx 'aes128-gcm@openssh.com'; then
        die "OpenSSH does not support aes128-gcm@openssh.com."
    fi

    set_config PERFORMANCE_MODE 1

    if [[ -f "$RUN_SCRIPT" ]]; then
        build_run_script
    fi

    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        systemctl restart "$UNIT_NAME"
    fi

    ok "Performance profile enabled."
    info "Run this option on both Iran and foreign servers."
}

disable_performance_profile() {
    need_root
    ensure_config_files

    rm -f "$PERF_SYSCTL"
    sysctl --system >/dev/null 2>&1 || true

    if [[ -f "$PERF_STATE" ]]; then
        local line key value

        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == *=* ]] || continue
            key="${line%%=*}"
            value="${line#*=}"
            sysctl -w "$key=$value" >/dev/null 2>&1 || true
        done < "$PERF_STATE"

        rm -f "$PERF_STATE"
    fi

    set_config PERFORMANCE_MODE 0

    if [[ -f "$RUN_SCRIPT" ]]; then
        build_run_script
    fi

    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
        systemctl restart "$UNIT_NAME"
    fi

    ok "Performance profile disabled and previous runtime values restored."
}

performance_menu() {
    while :; do
        header
        echo "${BOLD}🚀 Speed Optimization${RESET}"
        echo
        echo "  ${CYAN}1${RESET}) Enable optimized profile"
        echo "  ${CYAN}2${RESET}) Show current status"
        echo "  ${CYAN}3${RESET}) Disable and restore"
        echo "  ${CYAN}0${RESET}) Back"
        echo

        local choice
        choice=$(read_menu_choice "Select: " 3)

        case "$choice" in
            1) enable_performance_profile; pause_screen ;;
            2) performance_status; pause_screen ;;
            3) disable_performance_profile; pause_screen ;;
            0) return ;;
        esac
    done
}

build_run_script() {
    cat > "$RUN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/etc/reverse-ssh-tunnel"

CONFIG_FILE="$APP_DIR/config"
FORWARDS_FILE="$APP_DIR/forwards.conf"
KEY_FILE="$APP_DIR/id_ed25519"
KNOWN_HOSTS="$APP_DIR/known_hosts"

TUNNEL_USER="revtunnel"

get_config() {
    local key="$1"

    sed \
        -n \
        "s/^${key}=//p" \
        "$CONFIG_FILE" 2>/dev/null |
        tail -n1
}

server="$(get_config SERVER_HOST)"
ssh_port="$(get_config SSH_PORT)"

ssh_port="${ssh_port:-22}"
performance_mode="$(get_config PERFORMANCE_MODE)"

[[ -n "$server" ]] ||
    exit 1

[[ -s "$KEY_FILE" ]] ||
    exit 1

[[ -f "$KNOWN_HOSTS" ]] ||
    exit 1

[[ -f "$FORWARDS_FILE" ]] ||
    exit 1

args=(
    -M 0
    -N
    -T

    -o ServerAliveInterval=20
    -o ServerAliveCountMax=3

    -o ExitOnForwardFailure=yes
    -o BatchMode=yes

    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$KNOWN_HOSTS"

    -o ConnectTimeout=15

    -i "$KEY_FILE"
    -p "$ssh_port"
)

if [[ "$performance_mode" == "1" ]]; then
    args+=(
        -o Compression=no
        -o Ciphers=aes128-gcm@openssh.com,chacha20-poly1305@openssh.com
        -o "RekeyLimit=4G 1h"
    )
fi

forward_count=0

while IFS= read -r line || [[ -n "$line" ]]; do

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    mode="R"
    spec="$line"

    if [[ "$line" == *"|"* ]]; then
        mode="${line%%|*}"
        spec="${line#*|}"
    fi

    case "$mode" in
        L|R)
            args+=("-$mode" "$spec")
            ;;
        *)
            echo "Invalid forward mode in $FORWARDS_FILE: $line" >&2
            exit 1
            ;;
    esac

    forward_count=$((forward_count + 1))

done < "$FORWARDS_FILE"

(( forward_count > 0 )) ||
    exit 1

exec /usr/bin/autossh \
    "${args[@]}" \
    "$TUNNEL_USER@$server"
EOF

    chmod 700 "$RUN_SCRIPT"
}

install_systemd_service() {
    cat > "/etc/systemd/system/$UNIT_NAME" <<EOF
[Unit]
Description=Persistent SSH Tunnel Manager
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple

Environment=AUTOSSH_GATETIME=0
Environment=AUTOSSH_PORT=0

ExecStart=$RUN_SCRIPT

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 \
        "/etc/systemd/system/$UNIT_NAME"

    systemctl daemon-reload

    systemctl enable "$UNIT_NAME" >/dev/null
}

restart_tunnel() {
    need_root
    ensure_config_files

    local server

    server=$(get_config SERVER_HOST)

    if [[ -z "$server" ]]; then
        warn "Foreign server is not configured."
        return 1
    fi

    if [[ ! -s "$FORWARDS_FILE" ]]; then
        warn "No port forwards are configured."
        return 1
    fi

    [[ -f "$KEY_FILE" ]] ||
        die "SSH private key is missing."

    [[ -f "$KNOWN_HOSTS" ]] ||
        die "SSH known_hosts is missing."

    build_run_script
    install_systemd_service

    systemctl restart "$UNIT_NAME"

    sleep 2

    if systemctl is-active --quiet "$UNIT_NAME"; then
        ok "Tunnel service is running."
    else
        warn "Tunnel service failed to start."

        systemctl \
            --no-pager \
            --full \
            status "$UNIT_NAME" || true

        return 1
    fi
}

start_tunnel() {
    if systemctl is-active --quiet "$UNIT_NAME"; then
        ok "Tunnel is already running."
        return
    fi

    restart_tunnel
}

stop_tunnel() {
    if systemctl stop "$UNIT_NAME" 2>/dev/null; then
        ok "Tunnel stopped."
    else
        warn "Tunnel service is not installed or could not be stopped."
    fi
}

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

test_local_services() {
    ensure_config_files

    header

    echo "${BOLD}🧪 Test Iran-side Services${RESET}"
    echo

    local n=0
    local line
    local rb
    local rp
    local lh
    local lp
    local extra
    local mode
    local spec
    local test_host
    local test_port

    while IFS= read -r line || [[ -n "$line" ]]; do

        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        if [[ "$line" == *"|"* ]]; then
            mode="${line%%|*}"
            spec="${line#*|}"
        else
            mode="R"
            spec="$line"
        fi

        IFS=: read -r \
            rb rp lh lp extra \
            <<< "$spec"

        if [[ "$mode" == "L" ]]; then
            test_host="$rb"
            test_port="$rp"
        else
            test_host="$lh"
            test_port="$lp"
        fi

        n=$((n + 1))

        if timeout 3 \
            bash -c "</dev/tcp/$test_host/$test_port" \
            2>/dev/null; then

            ok "$n) $test_host:$test_port is reachable"

        else

            warn "$n) $test_host:$test_port is NOT reachable"

        fi

    done < "$FORWARDS_FILE"

    (( n > 0 )) ||
        warn "No forwards configured."
}

tunnel_status() {
    header

    echo "${BOLD}📊 Tunnel Status${RESET}"
    echo

    local server
    local port

    server=$(get_config SERVER_HOST)
    port=$(get_config SSH_PORT)

    port="${port:-22}"

    echo "🌍 Foreign server : ${server:-Not configured}"
    echo "🔌 SSH port       : $port"
    echo "👤 Tunnel user    : $TUNNEL_USER"

    echo

    if systemctl is-enabled \
        --quiet "$UNIT_NAME" 2>/dev/null; then

        ok "systemd: enabled"

    else

        warn "systemd: not enabled"

    fi

    if systemctl is-active \
        --quiet "$UNIT_NAME" 2>/dev/null; then

        ok "Tunnel service: ONLINE"

    else

        warn "Tunnel service: OFFLINE"

    fi

    echo

    list_forwards_raw

    echo
    echo "${BOLD}📝 Recent logs${RESET}"

    echo "────────────────────────────────────────────────────────────"

    journalctl \
        -u "$UNIT_NAME" \
        -n 15 \
        --no-pager \
        2>/dev/null || true
}

list_forwards_raw() {
    local entries=()

    mapfile -t entries < <(
        get_forward_entries
    )

    echo "${BOLD}🔗 Configured forwards${RESET}"

    if (( ${#entries[@]} == 0 )); then
        echo "  None"
        return
    fi

    local i=0
    local entry

    for entry in "${entries[@]}"; do
        i=$((i + 1))
        echo "  $i) $entry"
    done
}

show_logs() {
    clear_screen

    echo "${BOLD}📝 SSH Tunnel Logs${RESET}"
    echo

    journalctl \
        -u "$UNIT_NAME" \
        -n 100 \
        --no-pager \
        2>/dev/null || true

    echo

    pause_screen
}

# ---------------------------------------------------------------------
# Connection configuration
# ---------------------------------------------------------------------

configure_connection() {
    need_root

    ensure_key
    ensure_config_files

    header

    echo "${BOLD}🔗 Configure Foreign Server Connection${RESET}"
    echo

    local server
    local ssh_port

    read -r \
        -p "🌍 Foreign server IP or hostname: " \
        server

    [[ -n "$server" ]] ||
        die "Server address cannot be empty."

    valid_host "$server" ||
        die "Invalid server address."

    ssh_port=$(
        read_port_default \
            "🔌 Foreign SSH port [22]: " \
            "22"
    )

    echo
    info "Retrieving the foreign server SSH host key..."

    if ! safe_ssh_keyscan \
        "$server" \
        "$ssh_port"; then

        warn "Could not retrieve the SSH host key."
        warn "Check IP, SSH port, firewall and server availability."

        return 1
    fi

    ok "SSH host key saved."

    set_config SERVER_HOST "$server"
    set_config SSH_PORT "$ssh_port"

    echo
    echo "${BOLD}🔑 Public key installation method${RESET}"
    echo

    echo "  1) 🤖 Automatic using an administrative SSH account"
    echo "  2) 📋 Manual"
    echo "  0) ↩️  Cancel"

    echo

    local mode

    mode=$(read_menu_choice "Select: " 2)

    case "$mode" in

        0)
            return
            ;;

        1)

            local admin_user

            read -r \
                -p \
                "👤 Administrative SSH username [root]: " \
                admin_user

            admin_user="${admin_user:-root}"

            echo

            if ! install_key_automatically \
                "$server" \
                "$ssh_port" \
                "$admin_user"; then

                echo
                warn "Automatic installation failed."
                echo "Use the manual method instead."

                echo

                show_public_key

                return 1
            fi

            ;;

        2)

            echo

            show_public_key

            echo
            echo "On the foreign server:"
            echo
            echo "  🌍 Foreign server"
            echo "      ↓"
            echo "  🔑 Install Iran public key"

            pause_screen

            ;;

    esac

    echo

    if test_ssh_connection \
        "$server" \
        "$ssh_port"; then

        ok "Connection is ready."
        return 0
    fi

    warn "SSH test failed."

    return 1
}

# ---------------------------------------------------------------------
# Iran setup
# ---------------------------------------------------------------------

initial_iran_setup() {
    header

    echo "${BOLD}IR Iran Server Initial Setup${RESET}"
    echo

    install_packages \
        openssh-client \
        autossh \
        ca-certificates

    ensure_key
    ensure_config_files

    if ! configure_connection; then
        return 1
    fi

    echo
    echo "${BOLD}🔗 Add your first port forward${RESET}"
    echo

    echo "Example:"
    echo
    echo "  Germany egress (-L):"
    echo "  IR Iran 127.0.0.1:28888"
    echo "             ↓ SSH"
    echo "  🇩🇪 Germany 127.0.0.1:28433"

    echo

    if read_yes_no "Add a port forward now?"; then
        add_forward
    fi

    if [[ -s "$FORWARDS_FILE" ]]; then
        restart_tunnel || true
    fi
}

reconfigure_connection() {
    header

    echo "${BOLD}🔄 Reconfigure Foreign Connection${RESET}"
    echo

    configure_connection || true

    if [[ -s "$FORWARDS_FILE" ]]; then

        if read_yes_no "Restart the tunnel now?"; then
            restart_tunnel || true
        fi

    fi
}

# ---------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------

backup_configuration() {
    ensure_config_files

    local backup_dir="/root/reverse-ssh-tunnel-backups"
    local stamp
    local archive

    stamp=$(date '+%Y%m%d-%H%M%S')

    install -d \
        -m 700 \
        "$backup_dir"

    archive="$backup_dir/reverse-ssh-tunnel-$stamp.tar.gz"

    tar \
        -czf "$archive" \
        -C "$APP_DIR" \
        config \
        forwards.conf \
        known_hosts \
        id_ed25519.pub \
        2>/dev/null || {

        rm -f "$archive"

        die "Could not create backup."
    }

    chmod 600 "$archive"

    ok "Configuration backup created:"
    echo
    echo "  $archive"

    echo
    warn "The private SSH key is NOT included."
    warn "Do not copy private SSH keys into ordinary backups."
}

# ---------------------------------------------------------------------
# Iran uninstall
# ---------------------------------------------------------------------

uninstall_iran() {
    header

    echo "${BOLD}🗑️  Uninstall Iran-side Tunnel${RESET}"
    echo

    warn "This removes the systemd service and $APP_DIR."
    warn "It does not modify the foreign server."

    echo

    if ! read_yes_no "Continue?"; then
        return
    fi

    systemctl \
        disable \
        --now \
        "$UNIT_NAME" \
        2>/dev/null || true

    rm -f \
        "/etc/systemd/system/$UNIT_NAME"

    systemctl daemon-reload

    rm -rf "$APP_DIR"

    ok "Iran-side tunnel configuration removed."
}

# ---------------------------------------------------------------------
# Iran menu
# ---------------------------------------------------------------------

iran_menu() {
    while :; do

        header

        local server

        server=$(get_config SERVER_HOST)

        if [[ -n "$server" ]]; then

            if systemctl is-active \
                --quiet \
                "$UNIT_NAME" \
                2>/dev/null; then

                echo "Status: ${GREEN}🟢 ONLINE${RESET}"
                echo "Foreign: ${CYAN}$server${RESET}"

            else

                echo "Status: ${YELLOW}🔴 OFFLINE${RESET}"
                echo "Foreign: ${CYAN}$server${RESET}"

            fi

        else

            echo "Status: ${YELLOW}⚪ NOT CONFIGURED${RESET}"

        fi

        echo

        echo "  ${CYAN}1${RESET}) 🛠️  Initial setup / Connect"
        echo "  ${CYAN}2${RESET}) ➕ Add port forward"
        echo "  ${CYAN}3${RESET}) ➖ Remove port forward"
        echo "  ${CYAN}4${RESET}) 📋 List port forwards"
        echo "  ${CYAN}5${RESET}) 📊 Tunnel status"
        echo "  ${CYAN}6${RESET}) 🧪 Test Iran services"
        echo "  ${CYAN}7${RESET}) ▶️  Start tunnel"
        echo "  ${CYAN}8${RESET}) ⏹️  Stop tunnel"
        echo "  ${CYAN}9${RESET}) 🔄 Restart tunnel"
        echo "  ${CYAN}10${RESET}) 🔐 Test SSH connection"
        echo "  ${CYAN}11${RESET}) 📝 View logs"
        echo "  ${CYAN}12${RESET}) 🔑 Show public key"
        echo "  ${CYAN}13${RESET}) 🔄 Reconfigure connection"
        echo "  ${CYAN}14${RESET}) 💾 Backup configuration"
        echo "  ${CYAN}15${RESET}) 🗑️  Uninstall"
        echo "  ${CYAN}16${RESET}) 🚀 Speed optimization"
        echo "  ${CYAN}0${RESET}) 🚪 Back"

        echo

        local choice

        choice=$(read_menu_choice \
            "Select an option: " \
            16)

        case "$choice" in

            1)
                initial_iran_setup
                pause_screen
                ;;

            2)
                add_forward
                pause_screen
                ;;

            3)
                remove_forward
                pause_screen
                ;;

            4)
                list_forwards
                pause_screen
                ;;

            5)
                tunnel_status
                pause_screen
                ;;

            6)
                test_local_services
                pause_screen
                ;;

            7)
                start_tunnel
                pause_screen
                ;;

            8)
                stop_tunnel
                pause_screen
                ;;

            9)
                restart_tunnel
                pause_screen
                ;;

            10)
                test_ssh_connection \
                    "$(get_config SERVER_HOST)" \
                    "$(get_config SSH_PORT)" ||
                    true

                pause_screen
                ;;

            11)
                show_logs
                ;;

            12)
                show_public_key
                pause_screen
                ;;

            13)
                reconfigure_connection
                pause_screen
                ;;

            14)
                backup_configuration
                pause_screen
                ;;

            15)
                uninstall_iran
                pause_screen
                return
                ;;

            16)
                performance_menu
                ;;

            0)
                return
                ;;

        esac

    done
}

# ---------------------------------------------------------------------
# Foreign menu
# ---------------------------------------------------------------------

foreign_menu() {
    while :; do

        header

        if id "$TUNNEL_USER" >/dev/null 2>&1 &&
           [[ -f "$SSHD_DROPIN" ]]; then

            echo "Status: ${GREEN}🟢 READY${RESET}"

        else

            echo "Status: ${YELLOW}⚪ NOT CONFIGURED${RESET}"

        fi

        echo

        echo "  ${CYAN}1${RESET}) 🛠️  Initial setup"
        echo "  ${CYAN}2${RESET}) 🔑 Install Iran public key"
        echo "  ${CYAN}3${RESET}) 📊 Server status"
        echo "  ${CYAN}4${RESET}) 🔐 List authorized keys"
        echo "  ${CYAN}5${RESET}) 🗑️  Remove all tunnel keys"
        echo "  ${CYAN}6${RESET}) 🗑️  Uninstall"
        echo "  ${CYAN}7${RESET}) 🚀 Speed optimization"
        echo "  ${CYAN}0${RESET}) 🚪 Back"

        echo

        local choice

        choice=$(read_menu_choice \
            "Select an option: " \
            7)

        case "$choice" in

            1)
                foreign_setup
                pause_screen
                ;;

            2)
                foreign_add_key
                pause_screen
                ;;

            3)
                foreign_status
                pause_screen
                ;;

            4)
                foreign_list_keys
                pause_screen
                ;;

            5)
                foreign_remove_keys
                pause_screen
                ;;

            6)
                foreign_uninstall
                pause_screen
                return
                ;;

            7)
                performance_menu
                ;;

            0)
                return
                ;;

        esac

    done
}

# ---------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------

main_menu() {
    need_root
    detect_os

    while :; do

        header

        echo "${BOLD}Choose the role of this server:${RESET}"
        echo

        echo "  ${CYAN}1${RESET}) IR Iran / Source server"
        echo "  ${CYAN}2${RESET}) 🌍 Foreign / Destination server"
        echo "  ${CYAN}0${RESET}) 🚪 Exit"

        echo

        local choice

        choice=$(read_menu_choice \
            "Select: " \
            2)

        case "$choice" in

            1)
                iran_menu
                ;;

            2)
                foreign_menu
                ;;

            0)
                echo
                echo "👋 Goodbye."
                exit 0
                ;;

        esac

    done
}

main_menu
