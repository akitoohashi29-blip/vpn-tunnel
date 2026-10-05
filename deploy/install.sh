#!/bin/bash
set -euo pipefail

# VPN Tunnel Manager - Installation Script
# Usage: ./install.sh [iran|kharej] [options]

ROLE="${1:-}"
shift || true

IRAN_IP=""
IRAN_PORT=22
KHAREJ_IP=""
KHAREJ_PORT=22
SSH_USER="root"
PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --iran-ip) IRAN_IP="$2"; shift 2 ;;
        --iran-port) IRAN_PORT="$2"; shift 2 ;;
        --kharej-ip) KHAREJ_IP="$2"; shift 2 ;;
        --kharej-port) KHAREJ_PORT="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
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

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy binary (assumes it's in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_ROOT/$BINARY_NAME" ]]; then
    cp "$PROJECT_ROOT/$BINARY_NAME" "$INSTALL_DIR/"
elif [[ -f "$PROJECT_ROOT/cmd/vpn-manager/$BINARY_NAME" ]]; then
    cp "$PROJECT_ROOT/cmd/vpn-manager/$BINARY_NAME" "$INSTALL_DIR/"
else
    echo "Binary not found. Please build first: go build -o $BINARY_NAME ./cmd/vpn-manager"
    exit 1
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
Environment=HOME=/root
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
echo "Web UI: http://$(hostname -I | awk '{print $1}'):$PORT"
echo ""
echo "Commands:"
echo "  Status:  systemctl status $SERVICE_NAME"
echo "  Logs:    journalctl -u $SERVICE_NAME -f"
echo "  Restart: systemctl restart $SERVICE_NAME"
echo "  Stop:    systemctl stop $SERVICE_NAME"
echo ""

# Show status
sleep 2
systemctl status "$SERVICE_NAME" --no-pager