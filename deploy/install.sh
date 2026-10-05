#!/bin/bash
set -euo pipefail

# VPN Tunnel Manager - One-Line Install for Ubuntu 22.04
# Usage (from GitHub):
#   bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/main/deploy/install.sh) iran --iran-ip <IP>
#   bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/main/deploy/install.sh) kharej --kharej-ip <IP>
#
# Usage (local):
#   ./install.sh iran --iran-ip <IP>

REPO_URL="https://github.com/akitoohashi29-blip/vpn-tunnel"
RAW_BASE="https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/main"
GO_VERSION="1.23.0"

ROLE="${1:-}"
shift || true

IRAN_IP=""
IRAN_PORT=22
KHAREJ_IP=""
KHAREJ_PORT=22
SSH_USER="root"
PORT=8080
LOCAL_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --iran-ip) IRAN_IP="$2"; shift 2 ;;
        --iran-port) IRAN_PORT="$2"; shift 2 ;;
        --kharej-ip) KHAREJ_IP="$2"; shift 2 ;;
        --kharej-port) KHAREJ_PORT="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --local) LOCAL_BUILD=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$ROLE" != "iran" && "$ROLE" != "kharej" ]]; then
    echo "Usage: $0 [iran|kharej] [options]"
    echo "Options:"
    echo "  --iran-ip <ip>       Iran server IP (required for iran role)"
    echo "  --iran-port <port>   Iran SSH port (default: 22)"
    echo "  --kharej-ip <ip>     Kharej server IP (required for kharej role)"
    echo "  --kharej-port <port> Kharej SSH port (default: 22)"
    echo "  --ssh-user <user>    SSH username (default: root)"
    echo "  --port <port>        Web UI port (default: 8080)"
    echo "  --local              Build from local source (default: fetch from GitHub)"
    exit 1
fi

if [[ "$ROLE" == "iran" && -z "$IRAN_IP" ]]; then
    echo "Error: --iran-ip is required for iran role"
    exit 1
fi

if [[ "$ROLE" == "kharej" && -z "$KHAREJ_IP" ]]; then
    echo "Error: --kharej-ip is required for kharej role"
    exit 1
fi

echo "=== Installing VPN Tunnel Manager ($ROLE) ==="

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
    # Local build (for development)
    echo "Building from local source..."
    cp -r /c/Users/this/Desktop/vpn-tunnel/* .
    go build -o "$BINARY_NAME" ./cmd/vpn-manager
else
    # Fetch and build from GitHub
    echo "Fetching source from GitHub..."
    if command -v git &> /dev/null; then
        git clone --depth 1 "$REPO_URL" . 2>/dev/null || git pull
    else
        # Fallback: download main.go and go.mod only (minimal build)
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
echo "Web UI: http://$LOCAL_IP:$PORT"
echo ""
echo "Commands:"
echo "  Status:  systemctl status $SERVICE_NAME"
echo "  Logs:    journalctl -u $SERVICE_NAME -f"
echo "  Restart: systemctl restart $SERVICE_NAME"
echo "  Stop:    systemctl stop $SERVICE_NAME"
echo ""

sleep 2
systemctl status "$SERVICE_NAME" --no-pager