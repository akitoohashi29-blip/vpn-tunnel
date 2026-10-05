package ssh

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

type Tunnel struct {
	LocalPort  int
	RemotePort int
	RemoteHost string
	RemoteUser string
	KeyPath    string
	Cmd        *exec.Cmd
	mu         sync.Mutex
	running    bool
}

type TunnelManager struct {
	tunnels map[string]*Tunnel
	mu      sync.RWMutex
	keyPath string
}

func NewTunnelManager(keyPath string) *TunnelManager {
	return &TunnelManager{
		tunnels: make(map[string]*Tunnel),
		keyPath: keyPath,
	}
}

func (tm *TunnelManager) StartReverseTunnel(ctx context.Context, iranIP string, iranPort int, kharejUser, kharejIP string, kharejPort int) error {
	key := fmt.Sprintf("%s:%d->%s:%d", iranIP, iranPort, kharejIP, kharejPort)

	tm.mu.Lock()
	if _, exists := tm.tunnels[key]; exists {
		tm.mu.Unlock()
		return fmt.Errorf("tunnel already exists")
	}

	tunnel := &Tunnel{
		LocalPort:  iranPort,
		RemotePort: kharejPort,
		RemoteHost: kharejIP,
		RemoteUser: kharejUser,
		KeyPath:    tm.keyPath,
	}
	tm.tunnels[key] = tunnel
	tm.mu.Unlock()

	return tunnel.startReverse(ctx)
}

func (t *Tunnel) startReverse(ctx context.Context) error {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.running {
		return nil
	}

	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ServerAliveInterval=10",
		"-o", "ServerAliveCountMax=3",
		"-o", "ExitOnForwardFailure=yes",
		"-N", // No remote command
		"-R", fmt.Sprintf("%d:localhost:%d", t.RemotePort, t.LocalPort),
		"-i", t.KeyPath,
		fmt.Sprintf("%s@%s", t.RemoteUser, t.RemoteHost),
	}

	t.Cmd = exec.CommandContext(ctx, "ssh", args...)
	t.Cmd.Stdout = os.Stdout
	t.Cmd.Stderr = os.Stderr

	if err := t.Cmd.Start(); err != nil {
		return fmt.Errorf("failed to start ssh tunnel: %w", err)
	}

	t.running = true

	go func() {
		t.Cmd.Wait()
		t.mu.Lock()
		t.running = false
		t.mu.Unlock()
	}()

	time.Sleep(500 * time.Millisecond)
	return nil
}

func (tm *TunnelManager) StopTunnel(iranIP string, iranPort int, kharejIP string, kharejPort int) error {
	key := fmt.Sprintf("%s:%d->%s:%d", iranIP, iranPort, kharejIP, kharejPort)

	tm.mu.Lock()
	tunnel, exists := tm.tunnels[key]
	if exists {
		delete(tm.tunnels, key)
	}
	tm.mu.Unlock()

	if !exists {
		return nil
	}

	tunnel.mu.Lock()
	defer tunnel.mu.Unlock()

	if tunnel.Cmd != nil && tunnel.Cmd.Process != nil {
		return tunnel.Cmd.Process.Kill()
	}
	return nil
}

func (tm *TunnelManager) GetStatus(iranIP string, iranPort int, kharejIP string, kharejPort int) (bool, error) {
	key := fmt.Sprintf("%s:%d->%s:%d", iranIP, iranPort, kharejIP, kharejPort)

	tm.mu.RLock()
	tunnel, exists := tm.tunnels[key]
	tm.mu.RUnlock()

	if !exists {
		return false, nil
	}

	tunnel.mu.Lock()
	defer tunnel.mu.Unlock()
	return tunnel.running && tunnel.Cmd != nil && tunnel.Cmd.Process != nil, nil
}

func (tm *TunnelManager) ListTunnels() []map[string]interface{} {
	tm.mu.RLock()
	defer tm.mu.RUnlock()

	result := make([]map[string]interface{}, 0, len(tm.tunnels))
	for key, tunnel := range tm.tunnels {
		tunnel.mu.Lock()
		running := tunnel.running && tunnel.Cmd != nil && tunnel.Cmd.Process != nil
		tunnel.mu.Unlock()

		result = append(result, map[string]interface{}{
			"key":          key,
			"local_port":   tunnel.LocalPort,
			"remote_port":  tunnel.RemotePort,
			"remote_host":  tunnel.RemoteHost,
			"remote_user":  tunnel.RemoteUser,
			"running":      running,
		})
	}
	return result
}

func GenerateKeyPair(keyPath string) error {
	if _, err := os.Stat(keyPath); err == nil {
		return nil // Already exists
	}

	args := []string{
		"-t", "ed25519",
		"-f", keyPath,
		"-N", "",
		"-C", "vpn-tunnel-manager",
	}
	cmd := exec.Command("ssh-keygen", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func ReadPublicKey(keyPath string) (string, error) {
	pubPath := keyPath + ".pub"
	data, err := os.ReadFile(pubPath)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

func SetupAuthorizedKeys(keyPath, remoteUser, remoteHost string) error {
	pubKey, err := ReadPublicKey(keyPath)
	if err != nil {
		return err
	}

	cmd := exec.Command("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
		fmt.Sprintf("%s@%s", remoteUser, remoteHost),
		"mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '"+pubKey+"' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func TestConnection(user, host string, keyPath string, port int) error {
	args := []string{
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		"-i", keyPath,
		"-p", strconv.Itoa(port),
		fmt.Sprintf("%s@%s", user, host),
		"echo connected",
	}
	cmd := exec.Command("ssh", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("connection test failed: %s", string(output))
	}
	return nil
}

func GetLocalIP() (string, error) {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return "", err
	}
	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	return localAddr.IP.String(), nil
}

func EnsureSSHDir() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	sshDir := filepath.Join(homeDir, ".ssh")
	if err := os.MkdirAll(sshDir, 0700); err != nil {
		return "", err
	}
	return sshDir, nil
}

func GetDefaultKeyPath() (string, error) {
	sshDir, err := EnsureSSHDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(sshDir, "vpn_tunnel_key"), nil
}

type SSHClient struct {
	client *ssh.Client
	config *ssh.ClientConfig
}

func NewSSHClient(user, host string, keyPath string, port int) (*SSHClient, error) {
	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}

	signer, err := ssh.ParsePrivateKey(keyData)
	if err != nil {
		return nil, err
	}

	config := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}

	addr := fmt.Sprintf("%s:%d", host, port)
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return nil, err
	}

	return &SSHClient{client: client, config: config}, nil
}

func (s *SSHClient) Close() error {
	if s.client != nil {
		return s.client.Close()
	}
	return nil
}

func (s *SSHClient) RunCommand(cmd string) (string, error) {
	session, err := s.client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	output, err := session.CombinedOutput(cmd)
	return string(output), err
}

func (s *SSHClient) StartTunnel(localPort, remotePort int, remoteHost string) (io.Closer, error) {
	listener, err := net.Listen("tcp", fmt.Sprintf("localhost:%d", localPort))
	if err != nil {
		return nil, err
	}

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go s.handleConnection(conn, remotePort, remoteHost)
		}
	}()

	return listener, nil
}

func (s *SSHClient) handleConnection(localConn net.Conn, remotePort int, remoteHost string) {
	defer localConn.Close()

	remoteConn, err := s.client.Dial("tcp", fmt.Sprintf("%s:%d", remoteHost, remotePort))
	if err != nil {
		return
	}
	defer remoteConn.Close()

	go func() { io.Copy(remoteConn, localConn) }()
	io.Copy(localConn, remoteConn)
}

func ParseSSHConfig(configPath string) (map[string]string, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}

	result := make(map[string]string)
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) >= 2 {
			key := strings.ToLower(parts[0])
			value := strings.Join(parts[1:], " ")
			result[key] = value
		}
	}
	return result, scanner.Err()
}