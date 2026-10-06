package metrics

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Metrics struct {
	TargetIP    string
	PingMs      float64
	PacketLoss  float64
	BandwidthMbps float64
	Timestamp   time.Time
	History     []MetricPoint
	mu          sync.RWMutex
	maxHistory  int
}

type MetricPoint struct {
	Time     time.Time `json:"time"`
	PingMs   float64   `json:"ping_ms"`
	LossPct  float64   `json:"loss_pct"`
	BW_Mbps  float64   `json:"bw_mbps"`
}

func NewMetricsCollector(targetIP string, maxHistory int) *Metrics {
	if maxHistory <= 0 {
		maxHistory = 60
	}
	return &Metrics{
		TargetIP:   targetIP,
		maxHistory: maxHistory,
		History:    make([]MetricPoint, 0, maxHistory),
	}
}

func (m *Metrics) Collect(ctx context.Context) error {
	pingMs, lossPct, err := m.measurePing(ctx)
	if err != nil {
		return err
	}

	bwMbps, err := m.measureBandwidth(ctx)
	if err != nil {
		bwMbps = 0
	}

	m.mu.Lock()
	m.PingMs = pingMs
	m.PacketLoss = lossPct
	m.BandwidthMbps = bwMbps
	m.Timestamp = time.Now()

	m.History = append(m.History, MetricPoint{
		Time:     time.Now(),
		PingMs:   pingMs,
		LossPct:  lossPct,
		BW_Mbps:  bwMbps,
	})
	if len(m.History) > m.maxHistory {
		m.History = m.History[len(m.History)-m.maxHistory:]
	}
	m.mu.Unlock()

	return nil
}

func (m *Metrics) measurePing(ctx context.Context) (float64, float64, error) {
	cmd := exec.CommandContext(ctx, "ping", "-c", "10", "-i", "0.2", m.TargetIP)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return 0, 100, nil
		}
		return 0, 0, fmt.Errorf("ping failed: %s", string(output))
	}

	return parsePingOutput(string(output))
}

func parsePingOutput(output string) (float64, float64, error) {
	lines := strings.Split(output, "\n")
	var avgPing float64
	var lossPct float64

	lossRegex := regexp.MustCompile(`(\d+)% packet loss`)
	rttRegex := regexp.MustCompile(`rtt min/avg/max/mdev = [\d.]+/([\d.]+)/`)

	for _, line := range lines {
		if matches := lossRegex.FindStringSubmatch(line); len(matches) > 1 {
			lossPct, _ = strconv.ParseFloat(matches[1], 64)
		}
		if matches := rttRegex.FindStringSubmatch(line); len(matches) > 1 {
			avgPing, _ = strconv.ParseFloat(matches[1], 64)
		}
	}

	return avgPing, lossPct, nil
}

func (m *Metrics) measureBandwidth(ctx context.Context) (float64, error) {
	if _, err := exec.LookPath("iperf3"); err != nil {
		return m.estimateBandwidthViaSSH(ctx)
	}

	cmd := exec.CommandContext(ctx, "iperf3", "-c", m.TargetIP, "-t", "5", "-J")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return m.estimateBandwidthViaSSH(ctx)
	}

	return parseIperf3JSON(string(output))
}

func parseIperf3JSON(output string) (float64, error) {
	re := regexp.MustCompile(`"bits_per_second"\s*:\s*(\d+\.?\d*)`)
	matches := re.FindAllStringSubmatch(output, -1)
	var maxBps float64
	for _, m := range matches {
		if len(m) > 1 {
			bps, _ := strconv.ParseFloat(m[1], 64)
			if bps > maxBps {
				maxBps = bps
			}
		}
	}
	return maxBps / 1_000_000, nil
}

func (m *Metrics) estimateBandwidthViaSSH(ctx context.Context) (float64, error) {
	cmd := exec.CommandContext(ctx, "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
		fmt.Sprintf("root@%s", m.TargetIP),
		"dd if=/dev/zero bs=1M count=10 2>/dev/null | pv -rb 2>&1 | tail -1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return 0, nil
	}
	return parsePVOutput(string(output))
}

func parsePVOutput(output string) (float64, error) {
	re := regexp.MustCompile(`([\d.]+)\s*([KMGT]?i?B/s)`)
	matches := re.FindStringSubmatch(output)
	if len(matches) < 3 {
		return 0, nil
	}
	val, _ := strconv.ParseFloat(matches[1], 64)
	unit := matches[2]
	switch {
	case strings.HasPrefix(unit, "K"):
		return val / 125, nil
	case strings.HasPrefix(unit, "M"):
		return val * 8, nil
	case strings.HasPrefix(unit, "G"):
		return val * 8000, nil
	default:
		return val / 125000, nil
	}
}

func (m *Metrics) GetSnapshot() Metrics {
	m.mu.RLock()
	defer m.mu.RUnlock()

	history := make([]MetricPoint, len(m.History))
	copy(history, m.History)

	return Metrics{
		TargetIP:       m.TargetIP,
		PingMs:         m.PingMs,
		PacketLoss:     m.PacketLoss,
		BandwidthMbps:  m.BandwidthMbps,
		Timestamp:      m.Timestamp,
		History:        history,
	}
}

func (m *Metrics) StartCollection(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	m.Collect(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.Collect(ctx)
		}
	}
}

func CheckPort(host string, port int, timeout time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	dialer := &net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", fmt.Sprintf("%s:%d", host, port))
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func GetInterfaceStats(iface string) (rxBytes, txBytes uint64, err error) {
	data, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/rx_bytes", iface))
	if err != nil {
		return 0, 0, err
	}
	rxBytes, _ = strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)

	data, err = os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/tx_bytes", iface))
	if err != nil {
		return 0, 0, err
	}
	txBytes, _ = strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)

	return rxBytes, txBytes, nil
}