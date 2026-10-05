package config

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"
)

const CodePrefix = "vpn://"

type TunnelConfig struct {
	IranIP       string   `json:"iran_ip"`
	IranPort     int      `json:"iran_port"`
	SSHUser      string   `json:"ssh_user"`
	PubKey       string   `json:"pubkey"`
	TunnelPorts  []int    `json:"tunnel_ports"`
	CreatedAt    int64    `json:"created_at"`
	ExpiresAt    int64    `json:"expires_at,omitempty"`
}

func EncodeConfig(cfg *TunnelConfig) (string, error) {
	data, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(data)
	return CodePrefix + encoded, nil
}

func DecodeConfig(code string) (*TunnelConfig, error) {
	if len(code) < len(CodePrefix) || code[:len(CodePrefix)] != CodePrefix {
		return nil, fmt.Errorf("invalid code prefix")
	}
	encoded := code[len(CodePrefix):]
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	var cfg TunnelConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func NewTunnelConfig(iranIP string, iranPort int, sshUser string, pubKey string, ports []int, ttlHours int) *TunnelConfig {
	now := time.Now().Unix()
	return &TunnelConfig{
		IranIP:      iranIP,
		IranPort:    iranPort,
		SSHUser:     sshUser,
		PubKey:      pubKey,
		TunnelPorts: ports,
		CreatedAt:   now,
		ExpiresAt:   now + int64(ttlHours)*3600,
	}
}

func (c *TunnelConfig) IsExpired() bool {
	if c.ExpiresAt == 0 {
		return false
	}
	return time.Now().Unix() > c.ExpiresAt
}