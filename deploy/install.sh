#!/bin/bash
set -euo pipefail

# VPN Tunnel Manager - One-Line Install for Ubuntu 22.04+
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)

REPO_URL="https://github.com/akitoohashi29-blip/vpn-tunnel"
RAW_BASE="https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master"
GO_VERSION="1.23.0"

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

# Require root
[[ $EUID -ne 0 ]] && { echo -e "${red}Fatal: Run as root${plain}"; exit 1; }

# OS check (Ubuntu/Debian only for now)
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo -e "${red}Unsupported OS${plain}"; exit 1
fi

# Non-interactive mode: explicit flag OR piped stdin (curl | bash)
if [[ "${VPN_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    NONINTERACTIVE=1
else
    NONINTERACTIVE=0
fi

# Architecture
arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo -e "${red}Unsupported arch: $(uname -m)${plain}"; exit 1 ;;
    esac
}

# Helpers
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
detect_public_ip() {
    local ip=""
    for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        ip=$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '\n\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') && break
    done
    echo "$ip"
}
detect_local_ips() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1
}

# Unified prompt: interactive reads, non-interactive uses env var or default
# prompt_or_default VAR "prompt" "default" [ENV_VAR]
prompt_or_default() {
    local var="$1" prompt="$2" default="$3" env_var="${4:-$1}"
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        printf -v "$var" '%s' "${!env_var:-$default}"
    else
        read -rp "$prompt" "$var"
        [[ -z "${!var}" ]] && printf -v "$var" '%s' "$default"
    fi
}

# Install Go
install_go() {
    if command -v go &>/dev/null; then
        local ver=$(go version | awk '{print $3}' | sed 's/go//')
        [[ "$ver" == "$GO_VERSION"* ]] && { echo -e "${green}Go ${ver} already installed${plain}"; return 0; }
    fi
    echo -e "${green}Installing Go ${GO_VERSION}...${plain}"
    wget --progress=bar:force:noscroll "https://go.dev/dl/go${GO_VERSION}.linux-$(arch).tar.gz" -O /tmp/go.tar.gz
    echo -e "${green}Extracting...${plain}"
    tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc
    echo -e "${green}Go installed: $(go version)${plain}"
}

# Build from source
build_binary() {
    local install_dir="/opt/vpn-manager"
    local binary_name="vpn-manager"

    mkdir -p "$install_dir"
    cd "$install_dir"

    echo -e "${green}Fetching source...${plain}"
    if command -v git &>/dev/null; then
        git clone --depth 1 "$REPO_URL" . 2>/dev/null || git pull
    else
        mkdir -p cmd/vpn-manager internal/config internal/ssh internal/metrics internal/web/templates
        for f in \
            cmd/vpn-manager/main.go \
            go.mod \
            internal/config/config.go \
            internal/ssh/tunnel.go \
            internal/metrics/collector.go \
            internal/web/server.go \
            internal/web/templates/iran.html \
            internal/web/templates/kharej.html; do
            echo -n "  $f ... "
            curl -fsSL "$RAW_BASE/$f" -o "$f" && echo -e "${green}OK${plain}" || echo -e "${red}FAIL${plain}"
        done
    fi

    echo -e "${green}Downloading dependencies...${plain}"
    go mod tidy
    echo -e "${green}Building binary...${plain}"
    go build -v -o "$binary_name" ./cmd/vpn-manager
    chmod +x "$binary_name"
    echo -e "${green}Binary built: $install_dir/$binary_name${plain}"
}

# Generate systemd service
install_service() {
    local role="$1" port="$2" iran_ip="$3" iran_port="$4" kharej_ip="$5" kharej_port="$6" ssh_user="$7"
    local install_dir="/opt/vpn-manager"
    local binary_name="vpn-manager"
    local service_name="vpn-manager"

    cat > "/etc/systemd/system/$service_name.service" <<EOF
[Unit]
Description=VPN Tunnel Manager
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$install_dir
Environment=HOME=/root PATH=/usr/local/go/bin:/usr/bin:/bin
ExecStart=$install_dir/$binary_name -role=$role -port=$port -iran-ip=$iran_ip -iran-port=$iran_port -kharej-ip=$kharej_ip -kharej-port=$kharej_port -ssh-user=$ssh_user
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vpn-manager

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$install_dir /root/.ssh
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl restart "$service_name"
}

# Write install result for easy access
write_result() {
    local role="$1" ip="$2" port="$3" token="$4"
    local result_file="/etc/vpn-manager/install-result.env"
    install -d -m 700 /etc/vpn-manager
    umask 077
    cat > "$result_file" <<EOF
VPN_ROLE=$role
VPN_IP=$ip
VPN_PORT=$port
VPN_TOKEN=$token
VPN_DASHBOARD=http://$ip:$port
EOF
    chmod 600 "$result_file"
    echo -e "${green}Install result: $result_file${plain}"
}

# Main
echo -e "${green}=== VPN Tunnel Manager Installer ===${plain}"
echo ""

# Role selection
ROLE=""
if [[ "$NONINTERACTIVE" == "1" ]]; then
    ROLE="${VPN_ROLE:-}"
    [[ "$ROLE" != "iran" && "$ROLE" != "kharej" ]] && { echo -e "${red}Set VPN_ROLE=iran or VPN_ROLE=kharej${plain}"; exit 1; }
else
    echo "Select server role:"
    echo "  1) Iran Server  (generates connection code)"
    echo "  2) Kharej Server (connects using code from Iran)"
    echo ""
    while true; do
        read -rp "Enter choice [1/2]: " choice
        case $choice in
            1) ROLE="iran"; break ;;
            2) ROLE="kharej"; break ;;
            *) echo "Invalid choice" ;;
        esac
    done
fi

# IP detection
PUBLIC_IP=$(detect_public_ip)
LOCAL_IPS=($(detect_local_ips))

# Build candidate IPs
build_candidates() {
    local provided="$1"
    local candidates=()
    [[ -n "$provided" ]] && candidates+=("$provided (provided)")
    [[ -n "$PUBLIC_IP" ]] && candidates+=("$PUBLIC_IP (auto-detected public)")
    for lip in "${LOCAL_IPS[@]}"; do
        candidates+=("$lip (local)")
    done
    echo "${candidates[@]}"
}

# Get IP for role
get_ip() {
    local role="$1" provided_ip="$2" var_name="$3"
    local candidates=($(build_candidates "$provided_ip"))

    if [[ "$NONINTERACTIVE" == "1" ]]; then
        printf -v "$var_name" '%s' "${candidates[0]%% *}"
        return
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        read -rp "Enter ${role} server IP: " manual_ip
        printf -v "$var_name" '%s' "$manual_ip"
        return
    fi

    echo ""
    echo "Detected IP addresses for ${role} server:"
    for i in "${!candidates[@]}"; do
        echo "  $((i+1))) ${candidates[i]}"
    done
    echo "  $(( ${#candidates[@]} + 1 ))) Enter manually"
    echo ""

    while true; do
        read -rp "Select IP [1-${#candidates[@]}] or Enter for first: " selection
        selection=${selection:-1}
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidates[@]} )); then
            printf -v "$var_name" '%s' "${candidates[$((selection-1))]%% *}"
            return
        elif (( selection == ${#candidates[@]} + 1 )); then
            read -rp "Enter ${role} server IP manually: " manual_ip
            [[ -n "$manual_ip" ]] && { printf -v "$var_name" '%s' "$manual_ip"; return; }
        fi
        echo "Invalid selection"
    done
}

IRAN_IP=""
KHAREJ_IP=""
IRAN_PORT=22
KHAREJ_PORT=22
SSH_USER="root"
PORT=8080

if [[ "$ROLE" == "iran" ]]; then
    get_ip "iran" "${VPN_IRAN_IP:-}" "IRAN_IP"
else
    get_ip "kharej" "${VPN_KHAREJ_IP:-}" "KHAREJ_IP"
fi

# Optional overrides
[[ "$NONINTERACTIVE" == "1" ]] && {
    IRAN_PORT="${VPN_IRAN_PORT:-22}"
    KHAREJ_PORT="${VPN_KHAREJ_PORT:-22}"
    SSH_USER="${VPN_SSH_USER:-root}"
    PORT="${VPN_PORT:-8080}"
} || {
    prompt_or_default IRAN_PORT "Iran SSH port [22]: " "22" VPN_IRAN_PORT
    prompt_or_default KHAREJ_PORT "Kharej SSH port [22]: " "22" VPN_KHAREJ_PORT
    prompt_or_default SSH_USER "SSH user [root]: " "root" VPN_SSH_USER
    prompt_or_default PORT "Web UI port [8080]: " "8080" VPN_PORT
}

# Validate
[[ "$ROLE" == "iran" && -z "$IRAN_IP" ]] && { echo -e "${red}Iran IP required${plain}"; exit 1; }
[[ "$ROLE" == "kharej" && -z "$KHAREJ_IP" ]] && { echo -e "${red}Kharej IP required${plain}"; exit 1; }

echo ""
echo -e "${green}=== Installing VPN Tunnel Manager ($ROLE) ===${plain}"
echo "Role:       $ROLE"
echo "Iran IP:    ${IRAN_IP:-<not needed>}"
echo "Kharej IP:  ${KHAREJ_IP:-<not needed>}"
echo "SSH User:   $SSH_USER"
echo "Web Port:   $PORT"
echo ""

install_go
build_binary
install_service "$ROLE" "$PORT" "$IRAN_IP" "$IRAN_PORT" "$KHAREJ_IP" "$KHAREJ_PORT" "$SSH_USER"

# Wait for service to be ready (poll until active or failed)
echo -e "${green}Waiting for service to start...${plain}"
for i in {1..30}; do
    status=$(systemctl is-active vpn-manager 2>/dev/null || echo "inactive")
    [[ "$status" == "active" ]] && break
    [[ "$status" == "failed" ]] && { echo -e "${red}Service failed to start${plain}"; journalctl -u vpn-manager -n 30 --no-pager; exit 1; }
    sleep 1
done

# Get admin token from service logs
TOKEN=$(journalctl -u vpn-manager -n 30 --no-pager 2>/dev/null | grep -o 'token=[a-f0-9]\{32\}' | head -1 | cut -d= -f2)
[[ -z "$TOKEN" ]] && TOKEN="check logs: journalctl -u vpn-manager"

write_result "$ROLE" "${IRAN_IP:-$KHAREJ_IP}" "$PORT" "$TOKEN"

echo ""
echo -e "${green}┌─────────────────────────────────────────────────────────────┐${plain}"
echo -e "${green}│  DASHBOARD ACCESS                                           │${plain}"
echo -e "${green}├─────────────────────────────────────────────────────────────┤${plain}"
echo -e "${green}│  Local:     http://$(hostname -I | awk '{print $1}'):$PORT${plain}"
[[ -n "$PUBLIC_IP" ]] && echo -e "${green}│  Public:    http://$PUBLIC_IP:$PORT${plain}"
echo -e "${green}└─────────────────────────────────────────────────────────────┘${plain}"
echo ""
echo -e "${green}Admin Token: $TOKEN${plain}"
echo -e "${green}Config saved: /etc/vpn-manager/install-result.env${plain}"
echo ""
echo "Commands:"
echo "  Status:  systemctl status vpn-manager"
echo "  Logs:    journalctl -u vpn-manager -f"
echo "  Restart: systemctl restart vpn-manager"
echo "  Stop:    systemctl stop vpn-manager"
echo ""
systemctl status vpn-manager --no-pager