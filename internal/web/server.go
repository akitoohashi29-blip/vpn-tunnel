package web

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"sync"
	"time"

	"vpn-tunnel/internal/config"
	"vpn-tunnel/internal/metrics"
	"vpn-tunnel/internal/ssh"
)

//go:embed templates/*.html
var templatesFS embed.FS

type Server struct {
	role         string
	port         int
	iranIP       string
	iranPort     int
	kharejIP     string
	kharejPort   int
	sshUser      string
	keyPath      string
	tunnelMgr    *ssh.TunnelManager
	metricsColl  *metrics.Metrics
	adminToken   string
	mu           sync.RWMutex
	templates    *template.Template
	connected    bool
	connectTime  time.Time
}

func NewServer(role string, port int) *Server {
	keyPath, _ := ssh.GetDefaultKeyPath()
	s := &Server{
		role:      role,
		port:      port,
		keyPath:   keyPath,
		tunnelMgr: ssh.NewTunnelManager(keyPath),
		adminToken: generateToken(),
	}
	s.loadTemplates()
	return s
}

func (s *Server) loadTemplates() {
	s.templates = template.Must(template.ParseFS(templatesFS, "templates/*.html"))
}

func generateToken() string {
	b := make([]byte, 32)
	for i := range b {
		b[i] = byte(time.Now().UnixNano() >> (i % 8))
	}
	return fmt.Sprintf("%x", b)[:32]
}

func (s *Server) SetIranConfig(iranIP string, iranPort int, sshUser string) {
	s.iranIP = iranIP
	s.iranPort = iranPort
	s.sshUser = sshUser
}

func (s *Server) SetKharejConfig(kharejIP string, kharejPort int) {
	s.kharejIP = kharejIP
	s.kharejPort = kharejPort
}

func (s *Server) Start(ctx context.Context) error {
	if s.role == "iran" {
		if err := ssh.GenerateKeyPair(s.keyPath); err != nil {
			return fmt.Errorf("failed to generate key pair: %w", err)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/connect", s.authMiddleware(s.handleConnect))
	mux.HandleFunc("/api/disconnect", s.authMiddleware(s.handleDisconnect))
	mux.HandleFunc("/api/code", s.authMiddleware(s.handleCode))
	mux.HandleFunc("/api/metrics", s.handleMetrics)
	mux.HandleFunc("/api/token", s.handleToken)
	mux.HandleFunc("/events", s.handleSSE)

	addr := fmt.Sprintf(":%d", s.port)
	log.Printf("Starting %s server on %s", s.role, addr)
	return http.ListenAndServe(addr, mux)
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("X-Admin-Token")
		if token == "" {
			token = r.URL.Query().Get("token")
		}
		if token != s.adminToken {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	data := map[string]interface{}{
		"Role":       s.role,
		"IranIP":     s.iranIP,
		"IranPort":   s.iranPort,
		"KharejIP":   s.kharejIP,
		"KharejPort": s.kharejPort,
		"Token":      s.adminToken,
	}
	tmplName := s.role + ".html"
	if err := s.templates.ExecuteTemplate(w, tmplName, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	connected := s.connected
	connectTime := s.connectTime
	s.mu.RUnlock()

	tunnels := s.tunnelMgr.ListTunnels()

	json.NewEncoder(w).Encode(map[string]interface{}{
		"role":         s.role,
		"connected":    connected,
		"connect_time": connectTime,
		"tunnels":      tunnels,
		"token":        s.adminToken,
	})
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	if s.role == "iran" {
		http.Error(w, "Iran server doesn't accept connections", http.StatusBadRequest)
		return
	}

	cfg, err := config.DecodeConfig(req.Code)
	if err != nil {
		http.Error(w, "Invalid code: "+err.Error(), http.StatusBadRequest)
		return
	}

	if cfg.IsExpired() {
		http.Error(w, "Code expired", http.StatusBadRequest)
		return
	}

	s.kharejIP = cfg.IranIP
	s.kharejPort = cfg.IranPort
	s.sshUser = cfg.SSHUser

	if err := s.tunnelMgr.StartReverseTunnel(r.Context(), cfg.IranIP, cfg.IranPort, cfg.SSHUser, s.getLocalIP(), cfg.TunnelPorts[0]); err != nil {
		http.Error(w, "Failed to start tunnel: "+err.Error(), http.StatusInternalServerError)
		return
	}

	s.mu.Lock()
	s.connected = true
	s.connectTime = time.Now()
	s.mu.Unlock()

	s.metricsColl = metrics.NewMetricsCollector(cfg.IranIP, 60)
	go s.metricsColl.StartCollection(r.Context(), 5*time.Second)

	json.NewEncoder(w).Encode(map[string]string{"status": "connected"})
}

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	s.mu.Lock()
	s.connected = false
	s.connectTime = time.Time{}
	s.mu.Unlock()

	for _, t := range s.tunnelMgr.ListTunnels() {
		s.tunnelMgr.StopTunnel(
			t["remote_host"].(string),
			t["local_port"].(int),
			t["remote_host"].(string),
			t["remote_port"].(int),
		)
	}

	json.NewEncoder(w).Encode(map[string]string{"status": "disconnected"})
}

func (s *Server) handleCode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if s.role != "iran" {
		http.Error(w, "Only Iran server generates codes", http.StatusBadRequest)
		return
	}

	var req struct {
		KharejIP    string `json:"kharej_ip"`
		KharejPort  int    `json:"kharej_port"`
		SSHUser     string `json:"ssh_user"`
		TunnelPorts []int  `json:"tunnel_ports"`
		TTLHours    int    `json:"ttl_hours"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	if req.TTLHours == 0 {
		req.TTLHours = 24
	}
	if len(req.TunnelPorts) == 0 {
		req.TunnelPorts = []int{8080}
	}

	pubKey, err := ssh.ReadPublicKey(s.keyPath)
	if err != nil {
		http.Error(w, "Failed to read public key", http.StatusInternalServerError)
		return
	}

	cfg := config.NewTunnelConfig(s.iranIP, s.iranPort, s.sshUser, pubKey, req.TunnelPorts, req.TTLHours)
	code, err := config.EncodeConfig(cfg)
	if err != nil {
		http.Error(w, "Failed to encode config", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{"code": code})
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if s.metricsColl == nil {
		json.NewEncoder(w).Encode(map[string]interface{}{"error": "not connected"})
		return
	}
	snapshot := s.metricsColl.GetSnapshot()
	json.NewEncoder(w).Encode(snapshot)
}

func (s *Server) handleToken(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"token": s.adminToken})
}

func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}

	ctx := r.Context()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.mu.RLock()
			connected := s.connected
			connectTime := s.connectTime
			s.mu.RUnlock()

			data := map[string]interface{}{
				"connected":    connected,
				"connect_time": connectTime,
				"timestamp":    time.Now(),
			}

			if s.metricsColl != nil {
				snap := s.metricsColl.GetSnapshot()
				data["metrics"] = snap
			}

			jsonData, _ := json.Marshal(data)
			fmt.Fprintf(w, "data: %s\n\n", jsonData)
			flusher.Flush()
		}
	}
}

func (s *Server) getLocalIP() string {
	ip, _ := ssh.GetLocalIP()
	return ip
}

