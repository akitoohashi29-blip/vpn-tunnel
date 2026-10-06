#!/bin/bash
set -euo pipefail

# VPN Tunnel Manager - One-Line Install for Ubuntu 22.04
# Usage (from GitHub):
#   bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)
# Usage (local):
#   ./install.sh [--local]

REPO_URL="https://github.com/akitoohashi29-blip/vpn-tunnel"
RAW_BASE="https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master"
GO_VERSION="1.23.0"

ROLE=""
IRAN_IP=""
IRAN_PORT=22
KHAREJ_IP=""
KHAREJ_PORT=22
SSH_USER="root"
PORT=8080
LOCAL_BUILD=false
NON_INTERACTIVE=false

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --iran-ip) IRAN_IP="$2"; shift 2; NON_INTERACTIVE=true ;;
        --iran-port) IRAN_PORT="$2"; shift 2 ;;
        --kharej-ip) KHAREJ_IP="$2"; shift 2; NON_INTERACTIVE=true ;;
        --kharej-port) KHAREJ_PORT="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --role) ROLE="$2"; shift 2; NON_INTERACTIVE=true ;;
        --local) LOCAL_BUILD=true; shift ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Detect public IP
detect_public_ip() {
    local ip=""
    for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        ip=$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '\n\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') && break
    done
    echo "$ip"
}

# Detect local IPs (non-loopback)
detect_local_ips() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1
}

PUBLIC_IP=$(detect_public_ip)
LOCAL_IPS=($(detect_local_ips))

# Interactive role selection
if [[ -z "$ROLE" ]]; then
    echo "=== VPN Tunnel Manager Installer ==="
    echo ""
    echo "Select server role:"
    echo "  1) Iran Server  (generates connection code)"
    echo "  2) Kharej Server (connects using code from Iran)"
    echo ""
    read -p "Enter choice [1/2]: " choice
    case $choice in
        1) ROLE="iran" ;;
        2) ROLE="kharej" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

# Get IP with auto-detection and confirmation
get_ip_for_role() {
    local role=$1
    local provided_ip=""
    local detected_ip=""

    if [[ "$role" == "iran" ]]; then
        provided_ip="$IRAN_IP"
        detected_ip="$PUBLIC_IP"
    else
        provided_ip="$KHAREJ_IP"
        detected_ip="$PUBLIC_IP"
    fi

    # If provided via flag, use it
    if [[ -n "$provided_ip" && "$NON_INTERACTIVE" == true ]]; then
        echo "$provided_ip"
        return
    fi

    # Build list of candidate IPs
    local candidates=()
    [[ -n "$provided_ip" ]] && candidates+=("$provided_ip (provided)")
    [[ -n "$detected_ip" ]] && candidates+=("$detected_ip (auto-detected public)")
    for lip in "${LOCAL_IPS[@]}"; do
        candidates+=("$lip (local)")
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        read -p "Enter ${role} server IP: " manual_ip
        echo "$manual_ip"
        return
    fi

    if [[ "$NON_INTERACTIVE" == true ]]; then
        # In non-interactive mode, use first available
        echo "${candidates[0]%% *}"
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
        read -p "Select IP [1-${#candidates[@]}] or Enter for first: " selection
        selection=${selection:-1}
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidates[@]} )); then
            echo "${candidates[$((selection-1))]%% *}"
            return
        elif (( selection == ${#candidates[@]} + 1 )); then
            read -p "Enter ${role} server IP manually: " manual_ip
            [[ -n "$manual_ip" ]] && { echo "$manual_ip"; return; }
        fi
        echo "Invalid selection"
    done
}

# Get IPs
if [[ "$ROLE" == "iran" ]]; then
    IRAN_IP=$(get_ip_for_role "iran")
else
    KHAREJ_IP=$(get_ip_for_role "kharej")
fi

# Validate
if [[ "$ROLE" != "iran" && "$ROLE" != "kharej" ]]; then
    echo "Error: Role must be 'iran' or 'kharej'"
    exit 1
fi

if [[ "$ROLE" == "iran" && -z "$IRAN_IP" ]]; then
    echo "Error: Iran IP is required for iran role"
    exit 1
fi

if [[ "$ROLE" == "kharej" && -z "$KHAREJ_IP" ]]; then
    echo "Error: Kharej IP is required for kharej role"
    exit 1
fi

echo ""
echo "=== Installing VPN Tunnel Manager ($ROLE) ==="
echo "Iran IP:    ${IRAN_IP:-<not needed>}"
echo "Kharej IP:  ${KHAREJ_IP:-<not needed>}"
echo "SSH User:   $SSH_USER"
echo "Web Port:   $PORT"
echo ""

INSTALL_DIR="/opt/vpn-manager"
BINARY_NAME="vpn-manager"
SERVICE_NAME="vpn-manager"

# Install Go if not present
if ! command -v go &> /dev/null; then
    echo "Installing Go $GO_VERSION..."
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc
fi

export PATH=$PATH:/usr/local/go/bin

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [[ "$LOCAL_BUILD" == true && -f "/c/Users/this/Desktop/vpn-tunnel/cmd/vpn-manager/main.go" ]]; then
    echo "Building from local source..."
    cp -r /c/Users/this/Desktop/vpn-tunnel/* .
    go build -o "$BINARY_NAME" ./cmd/vpn-manager
else
    echo "Fetching source from GitHub..."
    if command -v git &> /dev/null; then
        git clone --depth 1 "$REPO_URL" . 2>/dev/null || git pull
    else
        mkdir -p cmd/vpn-manager internal/config internal/ssh internal/metrics internal/web/templates
        curl -fsSL "$RAW_BASE/cmd/vpn-manager/main.go" -o cmd/vpn-manager/main.go
        curl -fsSL "$RAW_BASE/go.mod" -o go.mod
        curl -fsSL "$RAW_BASE/internal/config/config.go" -o internal/config/config.go
        curl -fsSL "$RAW_BASE/internal/ssh/tunnel.go" -o internal/ssh/tunnel.go
        curl -fsSL "$RAW_BASE/internal/metrics/collector.go" -o internal/metrics/collector.go
        curl -fsSL "$RAW_BASE/internal/web/server.go" -o internal/web/server.go
        curl -fsSL "$RAW_BASE/internal/web/templates/iran.html" -o internal/web/templates/iran.html
        curl -fsSL "$RAW_BASE/internal/web/templates/kharej.html" -o internal/web/templates/kharej.html
    fi
    echo "Building..."
    go mod tidy
    go build -o "$BINARY_NAME" ./cmd/vpn-manager
fi

chmod +x "$INSTALL_DIR/$BINARY_NAME"

# Generate systemd service file
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=VPN Tunnel Manager
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
Environment=HOME=/root PATH=/usr/local/go/bin:/usr/bin:/bin
ExecStart=$INSTALL_DIR/$BINARY_NAME -role=$ROLE -port=$PORT -iran-ip=$IRAN_IP -iran-port=$IRAN_PORT -kharej-ip=$KHAREJ_IP -kharej-port=$KHAREJ_PORT -ssh-user=$SSH_USER
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
ReadWritePaths=$INSTALL_DIR /root/.ssh
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo ""
echo "=== Installation Complete ==="
echo "Service: $SERVICE_NAME"
echo "Role: $ROLE"
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  DASHBOARD ACCESS                                           │"
echo "├─────────────────────────────────────────────────────────────┤"
echo "│  Local:     http://$LOCAL_IP:$PORT"
if [[ -n "$PUBLIC_IP" ]]; then
    echo "│  Public:    http://$PUBLIC_IP:$PORT"
fi
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "Commands:"
echo "  Status:  systemctl status $SERVICE_NAME"
echo "  Logs:    journalctl -u $SERVICE_NAME -f"
echo "  Restart: systemctl restart $SERVICE_NAME"
echo "  Stop:    systemctl stop $SERVICE_NAME"
echo ""

sleep 2
systemctl status "$SERVICE_NAME" --no-pager