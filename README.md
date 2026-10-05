# VPN Tunnel Manager

A self-hosted VPN tunnel manager with web UI for creating SSH tunnels between an Iran server and a Kharej (outside Iran) server. Features real-time metrics including ping, packet loss, and bandwidth monitoring.

## One-Line Install (Ubuntu 22.04)

**Iran Server:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/main/deploy/install.sh) iran --iran-ip <YOUR_IRAN_IP>
```

**Kharej Server:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akitoohashi29-blip/vpn-tunnel/main/deploy/install.sh) kharej --kharej-ip <YOUR_KHAREJ_IP>
```

> The script auto-installs Go, builds the binary, sets up systemd, and starts the service.

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

## Quick Start

### 1. Build

```bash
git clone <repo>
cd vpn-tunnel
go build -o vpn-manager ./cmd/vpn-manager
```

### 2. Deploy to Iran Server

```bash
scp vpn-manager root@<IRAN_IP>:/opt/vpn-manager/
ssh root@<IRAN_IP> "cd /opt/vpn-manager && ./deploy/install.sh iran --iran-ip <IRAN_IP> --ssh-user root"
```

### 3. Deploy to Kharej Server

```bash
scp vpn-manager root@<KHAREJ_IP>:/opt/vpn-manager/
ssh root@<KHAREJ_IP> "cd /opt/vpn-manager && ./deploy/install.sh kharej --kharej-ip <KHAREJ_IP> --ssh-user root"
```

### 4. Create Tunnel

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

Real-time metrics collected every 5 seconds:
- **Ping**: ICMP round-trip time (ms)
- **Packet Loss**: Percentage from 10 pings
- **Bandwidth**: Via `iperf3` if available, otherwise SSH transfer estimate

## Service Management

```bash
# Status
systemctl status vpn-manager

# Logs
journalctl -u vpn-manager -f

# Restart
systemctl restart vpn-manager

# Stop
systemctl stop vpn-manager
```

## Security

- Ed25519 SSH keys (modern, fast, secure)
- `StrictHostKeyChecking=no` for automation (first connection only)
- `ServerAliveInterval=10` for dead peer detection
- systemd hardening: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`
- Token-based admin auth (32-char random token)

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

## Development

```bash
# Run locally (Iran)
go run ./cmd/vpn-manager -role=iran -port=8080 -iran-ip=1.2.3.4

# Run locally (Kharej)
go run ./cmd/vpn-manager -role=kharej -port=8080 -kharej-ip=5.6.7.8
```

## License

MIT