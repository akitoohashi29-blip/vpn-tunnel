# VPN Tunnel Manager

A self-hosted VPN tunnel manager with web UI for creating SSH tunnels between an Iran server and a Kharej (outside Iran) server. Features real-time metrics including ping, packet loss, and bandwidth monitoring.

## One-Line Install (Ubuntu 22.04+)

**Run on either server - fully interactive with IP auto-detection:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)
```

The installer will:
1. **Auto-detect your public IP** (via ifconfig.me, ipify.org, icanhazip.com, ipinfo.io)
2. **List all local IPs** (non-loopback interfaces)
3. **Prompt you to select** the correct IP or enter manually
4. **Ask for server role** (Iran or Kharej)
5. **Auto-install Go 1.23**, build, setup systemd, and start the service

**Non-interactive (for automation, cloud-init, scripts):**
```bash
# Iran server
VPN_NONINTERACTIVE=1 VPN_ROLE=iran VPN_IRAN_IP=<YOUR_IRAN_IP> bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)

# Kharej server
VPN_NONINTERACTIVE=1 VPN_ROLE=kharej VPN_KHAREJ_IP=<YOUR_KHAREJ_IP> bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)
```

**Environment variables for non-interactive mode:**
| Variable | Description | Default |
|----------|-------------|---------|
| `VPN_NONINTERACTIVE` | Set to `1` to skip all prompts | `0` (auto-detected from stdin) |
| `VPN_ROLE` | Server role: `iran` or `kharej` | *required* |
| `VPN_IRAN_IP` | Iran server public IP | *required for iran role* |
| `VPN_KHAREJ_IP` | Kharej server public IP | *required for kharej role* |
| `VPN_IRAN_PORT` | Iran SSH port | `22` |
| `VPN_KHAREJ_PORT` | Kharej SSH port | `22` |
| `VPN_SSH_USER` | SSH username | `root` |
| `VPN_PORT` | Web UI port | `8080` |

**Interactive flags (override prompts):**
```bash
# Iran server
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh) --role iran --iran-ip <YOUR_IRAN_IP>

# Kharej server
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh) --role kharej --kharej-ip <YOUR_KHAREJ_IP>
```

**Install script options:**
| Flag | Description |
|------|-------------|
| `--role iran\|kharej` | Set server role (skips interactive prompt) |
| `--iran-ip <ip>` | Iran server public IP |
| `--kharej-ip <ip>` | Kharej server public IP |
| `--iran-port <port>` | Iran SSH port (default: 22) |
| `--kharej-port <port>` | Kharej SSH port (default: 22) |
| `--ssh-user <user>` | SSH username (default: root) |
| `--port <port>` | Web UI port (default: 8080) |
| `--non-interactive` | Skip all prompts (requires --role and IP flags) |

## Architecture

```
┌─────────────────┐     SSH Reverse Tunnel      ┌─────────────────┐
│   Iran Server   │ ◄─────────────────────────► │  Kharej Server  │
│   (Dashboard)   │         Encrypted           │   (Dashboard)   │
│   Port: 8080    │                             │   Port: 8080    │
└─────────────────┘                             └─────────────────┘
       ▲                                               ▲
       │ HTTPS                                         │ HTTPS
       │                                               │
   Browser                                         Browser
```

- **Protocol**: SSH reverse tunnels (native SSH, no extra kernel modules)
- **Signaling**: Direct peer-to-peer via exchanged base64-encoded config code
- **Stack**: Go backend + vanilla JS/HTMX frontend (single binary, no build step)
- **Persistence**: systemd service on both servers
- **Auth**: Single admin, token-based (no database)

## Quick Start (One-Line Install)

**On Iran Server:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)
# Select: 1) Iran Server
# Confirm/enter your Iran public IP
```

**On Kharej Server:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/master/deploy/install.sh)
# Select: 2) Kharej Server
# Confirm/enter your Kharej public IP
```

That's it! Both dashboards will be available at `http://<SERVER_IP>:8080`

## Create Tunnel

1. Open Iran dashboard: `http://<IRAN_IP>:8080`
2. Enter Kharej server details (IP, SSH port, user, tunnel ports)
3. Click **Generate Code** → copy the `vpn://...` code
4. Open Kharej dashboard: `http://<KHAREJ_IP>:8080`
5. Paste the code → click **Connect**
6. Watch live metrics: ping, packet loss, bandwidth

## Configuration

### Iran Server Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-role` | Server role: `iran` or `kharej` | `iran` |
| `-port` | Web UI port | `8080` |
| `-iran-ip` | Iran server public IP | *required* |
| `-iran-port` | Iran SSH port | `22` |
| `-ssh-user` | SSH username | `root` |

### Kharej Server Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-role` | Server role: `iran` or `kharej` | `iran` |
| `-port` | Web UI port | `8080` |
| `-kharej-ip` | Kharej server public IP | *required* |
| `-kharej-port` | Kharej SSH port | `22` |
| `-ssh-user` | SSH username | `root` |

## Connection Code Format

The connection code is a base64url-encoded JSON with `vpn://` prefix:

```
vpn://<base64url(json)>
```

JSON structure:
```json
{
  "iran_ip": "1.2.3.4",
  "iran_port": 22,
  "ssh_user": "root",
  "pubkey": "ssh-ed25519 AAAAC3...",
  "tunnel_ports": [8080, 8081, 8082],
  "created_at": 1700000000,
  "expires_at": 1700086400
}
```

## SSH Key Setup

The manager auto-generates an Ed25519 key pair at `~/.ssh/vpn_tunnel_key` on first run. The public key must be added to the remote server's `authorized_keys`. The Iran dashboard's "Generate Code" button does this automatically via SSH.

## Metrics

Real-time metrics collected every 5 seconds via Server-Sent Events (SSE):
- **Ping**: ICMP round-trip time (ms) via `ping -c 10`
- **Packet Loss**: Percentage from 10 pings
- **Bandwidth**: Via `iperf3` if available, otherwise SSH transfer estimate

## Service Management

```bash
# Status
systemctl status vpn-manager

# Logs (includes admin token on startup)
journalctl -u vpn-manager -f

# Restart
systemctl restart vpn-manager

# Stop
systemctl stop vpn-manager

# View install result (dashboard URL, token, role)
cat /etc/vpn-manager/install-result.env
```

## Security

- Ed25519 SSH keys (modern, fast, secure)
- `StrictHostKeyChecking=no` for automation (first connection only)
- `ServerAliveInterval=10` for dead peer detection
- systemd hardening: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`
- Token-based admin auth (32-char random token)
- Install result file at `/etc/vpn-manager/install-result.env` (mode 600, root-only)

## Port Forwarding

Default tunnel ports: `8080, 8081, 8082` (configurable)

On Kharej server, these ports will forward to `localhost:<port>` on Iran server.

Example: Access Iran's port 8080 via `http://<KHAREJ_IP>:8080`

## Troubleshooting

### Connection fails
- Verify SSH access: `ssh -i ~/.ssh/vpn_tunnel_key root@<REMOTE_IP>`
- Check firewall: `ufw allow 22` and `ufw allow 8080`
- Check logs: `journalctl -u vpn-manager -f`

### Metrics not updating
- Ensure `ping` command available
- Install `iperf3` for bandwidth: `apt install iperf3`
- Check SSE connection in browser DevTools

### Tunnel drops
- Increase `ServerAliveInterval`/`ServerAliveCountMax` in ssh/tunnel.go
- Check for network instability between servers

### Service won't start
- Check logs: `journalctl -u vpn-manager -n 50`
- Verify binary exists: `ls -la /opt/vpn-manager/vpn-manager`
- Check Go version: `go version` (needs 1.23+)

## Development

```bash
# Run locally (Iran)
go run ./cmd/vpn-manager -role=iran -port=8080 -iran-ip=1.2.3.4

# Run locally (Kharej)
go run ./cmd/vpn-manager -role=kharej -port=8080 -kharej-ip=5.6.7.8
```

## License

MIT