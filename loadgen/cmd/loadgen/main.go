package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type requestMessage struct {
	ID      uint64 `json:"id"`
	Payload string `json:"payload"`
}

type responseMessage struct {
	ID       uint64 `json:"id"`
	Len      int    `json:"len"`
	Checksum uint32 `json:"checksum"`
}

type metricSample struct {
	Timestamp               string  `json:"ts"`
	ElapsedSeconds          int64   `json:"elapsed_seconds"`
	Phase                   string  `json:"phase"`
	StageIndex              int     `json:"stage_index"`
	TargetConns             int     `json:"target_connections"`
	TargetRPS               int     `json:"target_requests_per_second"`
	PayloadBytes            int     `json:"payload_bytes"`
	ActiveConns             int64   `json:"active_connections"`
	Sent                    uint64  `json:"sent"`
	Received                uint64  `json:"received"`
	Errors                  uint64  `json:"errors"`
	DispatchMisses          uint64  `json:"dispatch_misses"`
	SentPerSecond           uint64  `json:"sent_per_second"`
	ReceivedPerSecond       uint64  `json:"received_per_second"`
	ErrorsPerSecond         uint64  `json:"errors_per_second"`
	DispatchMissesPerSecond uint64  `json:"dispatch_misses_per_second"`
	P50LatencyMS            float64 `json:"p50_latency_ms"`
	P90LatencyMS            float64 `json:"p90_latency_ms"`
	P99LatencyMS            float64 `json:"p99_latency_ms"`
	MaxLatencyMS            float64 `json:"max_latency_ms"`
}

type summary struct {
	URL                     string         `json:"url"`
	URLs                    []string       `json:"urls"`
	Connections             int            `json:"connections"`
	ConnectionTargets       []int          `json:"connection_targets"`
	PayloadBytes            int            `json:"payload_bytes"`
	PayloadSweepBytes       []int          `json:"payload_sweep_bytes"`
	PayloadSweepSeconds     int            `json:"payload_sweep_seconds"`
	TargetRequestsPerSecond int            `json:"target_requests_per_second"`
	TargetMessagesPerSecond int            `json:"target_messages_per_second"`
	TargetConnectionRate    int            `json:"target_connection_rate"`
	BaselineSeconds         int            `json:"baseline_seconds"`
	SettleSeconds           int            `json:"settle_seconds"`
	StabilizeSeconds        int            `json:"stabilize_seconds"`
	TrafficSeconds          int            `json:"traffic_seconds"`
	CooldownSeconds         int            `json:"cooldown_seconds"`
	StartedAt               string         `json:"started_at"`
	FinishedAt              string         `json:"finished_at"`
	TotalSent               uint64         `json:"total_sent"`
	TotalReceived           uint64         `json:"total_received"`
	TotalErrors             uint64         `json:"total_errors"`
	TotalDispatchMisses     uint64         `json:"total_dispatch_misses"`
	PeakActiveConnections   int64          `json:"peak_active_connections"`
	Success                 bool           `json:"success"`
	P50LatencyMS            float64        `json:"p50_latency_ms"`
	P90LatencyMS            float64        `json:"p90_latency_ms"`
	P99LatencyMS            float64        `json:"p99_latency_ms"`
	MaxLatencyMS            float64        `json:"max_latency_ms"`
	Stages                  []stageSummary `json:"stages"`
}

type stageSummary struct {
	Index                   int     `json:"index"`
	Phase                   string  `json:"phase"`
	TargetConnections       int     `json:"target_connections"`
	TargetRequestsPerSecond int     `json:"target_requests_per_second"`
	PayloadBytes            int     `json:"payload_bytes"`
	StartedAt               string  `json:"started_at"`
	TrafficStartedAt        string  `json:"traffic_started_at"`
	TrafficFinishedAt       string  `json:"traffic_finished_at"`
	FinishedAt              string  `json:"finished_at"`
	RampSeconds             int     `json:"ramp_seconds"`
	TrafficSeconds          int     `json:"traffic_seconds"`
	StabilizeSeconds        int     `json:"stabilize_seconds"`
	ActiveConnections       int64   `json:"active_connections"`
	Sent                    uint64  `json:"sent"`
	Received                uint64  `json:"received"`
	Errors                  uint64  `json:"errors"`
	DispatchMisses          uint64  `json:"dispatch_misses"`
	P50LatencyMS            float64 `json:"p50_latency_ms"`
	P90LatencyMS            float64 `json:"p90_latency_ms"`
	P99LatencyMS            float64 `json:"p99_latency_ms"`
	MaxLatencyMS            float64 `json:"max_latency_ms"`
}

type target struct {
	raw     string
	addr    string
	host    string
	request string
}

type clientConn struct {
	id       int
	target   target
	payload  string
	sendCh   chan requestDispatch
	dead     atomic.Bool
	conn     net.Conn
	reader   *bufio.Reader
	active   *atomic.Int64
	peak     *atomic.Int64
	sent     *atomic.Uint64
	received *atomic.Uint64
	errors   *atomic.Uint64
	inFlight atomic.Bool
	latency  chan<- latencySample
	register chan<- *clientConn
	marker   *atomic.Value
	errorLog *errorLogger
}

type requestDispatch struct {
	id         uint64
	stageIndex int
	payload    string
}

type latencySample struct {
	stageIndex int
	ms         float64
}

type runMarker struct {
	Phase        string
	StageIndex   int
	TargetConns  int
	TargetRPS    int
	PayloadBytes int
}

type loadgenErrorSample struct {
	Timestamp      string `json:"ts"`
	ElapsedSeconds int64  `json:"elapsed_seconds"`
	Phase          string `json:"phase"`
	StageIndex     int    `json:"stage_index"`
	TargetConns    int    `json:"target_connections"`
	PayloadBytes   int    `json:"payload_bytes"`
	Operation      string `json:"operation"`
	ConnectionID   int    `json:"connection_id"`
	Target         string `json:"target"`
	RequestID      uint64 `json:"request_id,omitempty"`
	Error          string `json:"error"`
}

type errorLogger struct {
	mu        sync.Mutex
	encoder   *json.Encoder
	startedAt time.Time
}

func main() {
	var targetURL string
	var targetURLs string
	var connections int
	var connectionTargets string
	var payloadBytes int
	var payloadSweepBytesRaw string
	var payloadSweepSeconds int
	var requestsPerSecond int
	var targetConnectionRate int
	var baselineSeconds int
	var settleSeconds int
	var stabilizeSeconds int
	var trafficSeconds int
	var cooldownSeconds int
	var outputDir string

	flag.StringVar(&targetURL, "url", "http://127.0.0.1:8080/json", "HTTP JSON URL")
	flag.StringVar(&targetURLs, "urls", "", "comma-separated HTTP JSON URLs; overrides --url when set")
	flag.IntVar(&connections, "connections", 1_000_000, "number of persistent HTTP connections")
	flag.StringVar(&connectionTargets, "connection-targets", "", "comma- or space-separated persistent connection targets; overrides --connections when set")
	flag.IntVar(&payloadBytes, "payload-bytes", 256, "payload string size in bytes")
	flag.StringVar(&payloadSweepBytesRaw, "payload-sweep-bytes", "", "comma- or space-separated payload sizes to send after the request-rate ramp; empty disables the sweep")
	flag.IntVar(&payloadSweepSeconds, "payload-sweep-seconds", 0, "seconds to send each payload size in --payload-sweep-bytes")
	flag.IntVar(&requestsPerSecond, "requests-per-second", 100_000, "final global target requests per second")
	flag.IntVar(&targetConnectionRate, "target-connection-rate", 50_000, "target new HTTP connections per second during ramp")
	flag.IntVar(&baselineSeconds, "baseline-seconds", 0, "seconds to sample before opening connections")
	flag.IntVar(&settleSeconds, "settle-seconds", 0, "seconds to hold connections idle after ramp")
	flag.IntVar(&stabilizeSeconds, "stabilize-seconds", -1, "seconds to hold all current connections idle after traffic; defaults to --settle-seconds")
	flag.IntVar(&trafficSeconds, "traffic-seconds", 10, "seconds to ramp benchmark requests up to --requests-per-second")
	flag.IntVar(&cooldownSeconds, "cooldown-seconds", 0, "seconds to sample after traffic stops while connections stay open")
	flag.StringVar(&outputDir, "output", "runs/manual", "output run directory")
	flag.Parse()

	connectionSchedule, err := parseConnectionTargets(connectionTargets, connections)
	if err != nil {
		fatalf("parse connection targets: %v", err)
	}
	payloadSweepBytes, err := parsePayloadSizes(payloadSweepBytesRaw)
	if err != nil {
		fatalf("parse payload sweep sizes: %v", err)
	}
	maxConnections := connectionSchedule[len(connectionSchedule)-1]
	if stabilizeSeconds < 0 {
		stabilizeSeconds = settleSeconds
	}
	if maxConnections <= 0 || payloadBytes < 0 || payloadSweepSeconds < 0 || requestsPerSecond <= 0 || targetConnectionRate <= 0 || baselineSeconds < 0 || settleSeconds < 0 || stabilizeSeconds < 0 || trafficSeconds <= 0 || cooldownSeconds < 0 {
		fatalf("invalid arguments")
	}
	if len(payloadSweepBytes) > 0 && payloadSweepSeconds == 0 {
		fatalf("--payload-sweep-seconds must be positive when --payload-sweep-bytes is set")
	}

	targets, err := parseTargets(targetURL, targetURLs)
	if err != nil {
		fatalf("parse target URLs: %v", err)
	}

	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		fatalf("create output directory: %v", err)
	}

	metricsPath := filepath.Join(outputDir, "loadgen_metrics.jsonl")
	metricsFile, err := os.Create(metricsPath)
	if err != nil {
		fatalf("create %s: %v", metricsPath, err)
	}
	defer metricsFile.Close()

	errorPath := filepath.Join(outputDir, "loadgen_errors.jsonl")
	errorFile, err := os.Create(errorPath)
	if err != nil {
		fatalf("create %s: %v", errorPath, err)
	}
	defer errorFile.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	startedAt := time.Now().UTC()
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	errorLog := &errorLogger{encoder: json.NewEncoder(errorFile), startedAt: startedAt}

	payload := strings.Repeat("x", payloadBytes)
	var active atomic.Int64
	var peak atomic.Int64
	var sent atomic.Uint64
	var received atomic.Uint64
	var errorsCount atomic.Uint64
	var dispatchMisses atomic.Uint64
	var requestID atomic.Uint64

	latencyCh := make(chan latencySample, 1_000_000)
	registerCh := make(chan *clientConn, maxConnections)
	marker := atomic.Value{}
	marker.Store(runMarker{Phase: "baseline", StageIndex: -1, TargetConns: 0, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})

	var activeMu sync.Mutex
	activeConns := make([]*clientConn, 0, maxConnections)
	go func() {
		for conn := range registerCh {
			activeMu.Lock()
			activeConns = append(activeConns, conn)
			activeMu.Unlock()
		}
	}()

	var wg sync.WaitGroup

	var metricsWG sync.WaitGroup
	allLatencies := make([]float64, 0, min(maxConnections*trafficSeconds, 10_000_000))
	var allLatenciesMu sync.Mutex
	metricsWG.Add(1)
	go func() {
		defer metricsWG.Done()
		sampleMetrics(runCtx, startedAt, &marker, metricsFile, &active, &sent, &received, &errorsCount, &dispatchMisses, latencyCh, func(values []latencySample) {
			allLatenciesMu.Lock()
			for _, value := range values {
				allLatencies = append(allLatencies, value.ms)
			}
			allLatenciesMu.Unlock()
		})
	}()

	if waitPhase(runCtx, time.Duration(baselineSeconds)*time.Second) != nil {
		cancel()
	}

	stages := make([]stageSummary, 0, len(connectionSchedule)+len(payloadSweepBytes))
	for index, targetConnections := range connectionSchedule {
		if runCtx.Err() != nil {
			break
		}

		stageStarted := time.Now().UTC()
		stageSentStart := sent.Load()
		stageReceivedStart := received.Load()
		stageErrorsStart := errorsCount.Load()
		stageDispatchMissesStart := dispatchMisses.Load()
		allLatenciesMu.Lock()
		stageLatencyStart := len(allLatencies)
		allLatenciesMu.Unlock()

		marker.Store(runMarker{Phase: "ramp", StageIndex: index, TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		rampStartedAt := time.Now().UTC()
		openConnections(runCtx, targetConnections, targetConnectionRate, targets, payload, &active, &peak, &sent, &received, &errorsCount, latencyCh, registerCh, &wg, &marker, errorLog)
		rampSeconds := int(math.Ceil(time.Since(rampStartedAt).Seconds()))
		if active.Load() < int64(targetConnections) {
			cancel()
		}

		marker.Store(runMarker{Phase: "settle", StageIndex: index, TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		if waitPhase(runCtx, time.Duration(settleSeconds)*time.Second) != nil {
			cancel()
		}

		marker.Store(runMarker{Phase: "traffic", StageIndex: index, TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		trafficStartedAt := time.Now().UTC()
		trafficFinishedAt := trafficStartedAt.Add(time.Duration(trafficSeconds) * time.Second)
		if runCtx.Err() == nil {
			sendRequests(runCtx, trafficStartedAt, trafficFinishedAt, requestsPerSecond, index, payload, true, &requestID, &errorsCount, &dispatchMisses, &activeMu, &activeConns, &marker, errorLog)
			waitForInFlight(runCtx, &activeMu, &activeConns)
		}
		trafficEndedAt := time.Now().UTC()

		marker.Store(runMarker{Phase: "stabilize", StageIndex: index, TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		if waitPhase(runCtx, time.Duration(stabilizeSeconds)*time.Second) != nil {
			cancel()
		}

		finishedAt := time.Now().UTC()
		allLatenciesMu.Lock()
		stageLatencies := append([]float64(nil), allLatencies[stageLatencyStart:]...)
		allLatenciesMu.Unlock()
		stages = append(stages, stageSummary{
			Index:                   index,
			Phase:                   "traffic",
			TargetConnections:       targetConnections,
			TargetRequestsPerSecond: requestsPerSecond,
			PayloadBytes:            payloadBytes,
			StartedAt:               stageStarted.Format(time.RFC3339),
			TrafficStartedAt:        trafficStartedAt.Format(time.RFC3339),
			TrafficFinishedAt:       trafficEndedAt.Format(time.RFC3339),
			FinishedAt:              finishedAt.Format(time.RFC3339),
			RampSeconds:             rampSeconds,
			TrafficSeconds:          trafficSeconds,
			StabilizeSeconds:        stabilizeSeconds,
			ActiveConnections:       active.Load(),
			Sent:                    sent.Load() - stageSentStart,
			Received:                received.Load() - stageReceivedStart,
			Errors:                  errorsCount.Load() - stageErrorsStart,
			DispatchMisses:          dispatchMisses.Load() - stageDispatchMissesStart,
			P50LatencyMS:            percentile(stageLatencies, 50),
			P90LatencyMS:            percentile(stageLatencies, 90),
			P99LatencyMS:            percentile(stageLatencies, 99),
			MaxLatencyMS:            percentile(stageLatencies, 100),
		})
	}

	if runCtx.Err() == nil && len(payloadSweepBytes) > 0 {
		for _, sweepPayloadBytes := range payloadSweepBytes {
			stageIndex := len(stages)
			sweepPayload := strings.Repeat("x", sweepPayloadBytes)
			stageStarted := time.Now().UTC()
			stageSentStart := sent.Load()
			stageReceivedStart := received.Load()
			stageErrorsStart := errorsCount.Load()
			stageDispatchMissesStart := dispatchMisses.Load()
			allLatenciesMu.Lock()
			stageLatencyStart := len(allLatencies)
			allLatenciesMu.Unlock()

			marker.Store(runMarker{Phase: "payload_sweep", StageIndex: stageIndex, TargetConns: maxConnections, TargetRPS: requestsPerSecond, PayloadBytes: sweepPayloadBytes})
			trafficStartedAt := time.Now().UTC()
			trafficFinishedAt := trafficStartedAt.Add(time.Duration(payloadSweepSeconds) * time.Second)
			sendRequests(runCtx, trafficStartedAt, trafficFinishedAt, requestsPerSecond, stageIndex, sweepPayload, false, &requestID, &errorsCount, &dispatchMisses, &activeMu, &activeConns, &marker, errorLog)
			waitForInFlight(runCtx, &activeMu, &activeConns)
			trafficEndedAt := time.Now().UTC()

			allLatenciesMu.Lock()
			stageLatencies := append([]float64(nil), allLatencies[stageLatencyStart:]...)
			allLatenciesMu.Unlock()
			stages = append(stages, stageSummary{
				Index:                   stageIndex,
				Phase:                   "payload_sweep",
				TargetConnections:       maxConnections,
				TargetRequestsPerSecond: requestsPerSecond,
				PayloadBytes:            sweepPayloadBytes,
				StartedAt:               stageStarted.Format(time.RFC3339),
				TrafficStartedAt:        trafficStartedAt.Format(time.RFC3339),
				TrafficFinishedAt:       trafficEndedAt.Format(time.RFC3339),
				FinishedAt:              time.Now().UTC().Format(time.RFC3339),
				RampSeconds:             0,
				TrafficSeconds:          payloadSweepSeconds,
				StabilizeSeconds:        0,
				ActiveConnections:       active.Load(),
				Sent:                    sent.Load() - stageSentStart,
				Received:                received.Load() - stageReceivedStart,
				Errors:                  errorsCount.Load() - stageErrorsStart,
				DispatchMisses:          dispatchMisses.Load() - stageDispatchMissesStart,
				P50LatencyMS:            percentile(stageLatencies, 50),
				P90LatencyMS:            percentile(stageLatencies, 90),
				P99LatencyMS:            percentile(stageLatencies, 99),
				MaxLatencyMS:            percentile(stageLatencies, 100),
			})
		}
	}

	marker.Store(runMarker{Phase: "cooldown", StageIndex: len(stages) - 1, TargetConns: maxConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
	if waitPhase(runCtx, time.Duration(cooldownSeconds)*time.Second) != nil {
		cancel()
	}

	cancel()
	wg.Wait()
	close(registerCh)
	metricsWG.Wait()

	allLatenciesMu.Lock()
	overallP50 := percentile(allLatencies, 50)
	overallP90 := percentile(allLatencies, 90)
	overallP99 := percentile(allLatencies, 99)
	overallMax := percentile(allLatencies, 100)
	allLatenciesMu.Unlock()

	urls := make([]string, 0, len(targets))
	for _, target := range targets {
		urls = append(urls, target.raw)
	}

	s := summary{
		URL:                     urls[0],
		URLs:                    urls,
		Connections:             maxConnections,
		ConnectionTargets:       connectionSchedule,
		PayloadBytes:            payloadBytes,
		PayloadSweepBytes:       payloadSweepBytes,
		PayloadSweepSeconds:     payloadSweepSeconds,
		TargetRequestsPerSecond: requestsPerSecond,
		TargetMessagesPerSecond: requestsPerSecond,
		TargetConnectionRate:    targetConnectionRate,
		BaselineSeconds:         baselineSeconds,
		SettleSeconds:           settleSeconds,
		StabilizeSeconds:        stabilizeSeconds,
		TrafficSeconds:          trafficSeconds,
		CooldownSeconds:         cooldownSeconds,
		StartedAt:               startedAt.Format(time.RFC3339),
		FinishedAt:              time.Now().UTC().Format(time.RFC3339),
		TotalSent:               sent.Load(),
		TotalReceived:           received.Load(),
		TotalErrors:             errorsCount.Load(),
		TotalDispatchMisses:     dispatchMisses.Load(),
		PeakActiveConnections:   peak.Load(),
		Success:                 peak.Load() >= int64(maxConnections),
		P50LatencyMS:            overallP50,
		P90LatencyMS:            overallP90,
		P99LatencyMS:            overallP99,
		MaxLatencyMS:            overallMax,
		Stages:                  stages,
	}

	writeJSON(filepath.Join(outputDir, "summary.json"), s)
	fmt.Printf("wrote run data to %s\n", outputDir)

	if s.PeakActiveConnections < int64(maxConnections) {
		os.Exit(2)
	}
}

func (c *clientConn) run(ctx context.Context) {
	defer c.dead.Store(true)

	dialer := net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", c.target.addr)
	if err != nil {
		c.errors.Add(1)
		c.logError("dial", 0, err)
		return
	}

	c.conn = conn
	c.reader = bufio.NewReaderSize(conn, 4096)
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		_ = tcpConn.SetKeepAlive(true)
		_ = tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}

	if err := c.warmup(); err != nil {
		c.errors.Add(1)
		c.logError("warmup", 0, err)
		_ = conn.Close()
		return
	}

	c.register <- c
	activeNow := c.active.Add(1)
	updatePeak(c.peak, activeNow)
	defer c.active.Add(-1)
	defer conn.Close()

	for {
		select {
		case <-ctx.Done():
			return
		case request := <-c.sendCh:
			err := c.send(request)
			if err != nil {
				c.dead.Store(true)
				c.inFlight.Store(false)
				c.errors.Add(1)
				c.logError("request", request.id, err)
				return
			}
			c.inFlight.Store(false)
		}
	}
}

func (c *clientConn) warmup() error {
	req := fmt.Sprintf("GET /health HTTP/1.1\r\nHost: %s\r\nUser-Agent: bench-loadgen/0.1\r\nConnection: keep-alive\r\n\r\n", c.target.host)
	if err := c.conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return err
	}
	if _, err := io.WriteString(c.conn, req); err != nil {
		return err
	}
	resp, err := http.ReadResponse(c.reader, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("warmup status %d", resp.StatusCode)
	}
	return c.conn.SetDeadline(time.Time{})
}

func (c *clientConn) send(requestDispatch requestDispatch) error {
	payload := requestDispatch.payload
	if payload == "" {
		payload = c.payload
	}
	message := requestMessage{ID: requestDispatch.id, Payload: payload}
	body, err := json.Marshal(message)
	if err != nil {
		return err
	}

	request := fmt.Sprintf(
		"POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: bench-loadgen/0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n",
		c.target.request,
		c.target.host,
		len(body),
	)

	started := time.Now()
	if err := c.conn.SetDeadline(started.Add(30 * time.Second)); err != nil {
		return err
	}
	if _, err := io.WriteString(c.conn, request); err != nil {
		return err
	}
	if _, err := c.conn.Write(body); err != nil {
		return err
	}
	c.sent.Add(1)

	resp, err := http.ReadResponse(c.reader, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}

	var response responseMessage
	if err := json.Unmarshal(data, &response); err != nil {
		return err
	}
	expectedChecksum := checksum(payload)
	if response.ID != requestDispatch.id || response.Len != len(payload) || response.Checksum != expectedChecksum {
		return fmt.Errorf("unexpected response: id=%d len=%d checksum=%d", response.ID, response.Len, response.Checksum)
	}

	c.received.Add(1)
	latencyMS := float64(time.Since(started).Microseconds()) / 1000
	select {
	case c.latency <- latencySample{stageIndex: requestDispatch.stageIndex, ms: latencyMS}:
	default:
		c.errors.Add(1)
		c.logError("latency_buffer", requestDispatch.id, errors.New("latency sample buffer full"))
	}

	return c.conn.SetDeadline(time.Time{})
}

func (c *clientConn) logError(operation string, requestID uint64, err error) {
	if c.errorLog == nil || err == nil {
		return
	}
	marker := currentMarker(c.marker)
	c.errorLog.write(loadgenErrorSample{
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
		ElapsedSeconds: int64(time.Since(c.errorLog.startedAt).Seconds()),
		Phase:          marker.Phase,
		StageIndex:     marker.StageIndex,
		TargetConns:    marker.TargetConns,
		PayloadBytes:   marker.PayloadBytes,
		Operation:      operation,
		ConnectionID:   c.id,
		Target:         c.target.raw,
		RequestID:      requestID,
		Error:          err.Error(),
	})
}

func parseTargets(defaultURL string, csvURLs string) ([]target, error) {
	value := defaultURL
	if strings.TrimSpace(csvURLs) != "" {
		value = csvURLs
	}

	parts := strings.Split(value, ",")
	targets := make([]target, 0, len(parts))
	for _, part := range parts {
		raw := strings.TrimSpace(part)
		if raw == "" {
			continue
		}

		parsed, err := url.Parse(raw)
		if err != nil {
			return nil, err
		}
		if parsed.Scheme != "http" {
			return nil, fmt.Errorf("%s uses %q; only http is supported", raw, parsed.Scheme)
		}
		if parsed.Host == "" {
			return nil, fmt.Errorf("%s has no host", raw)
		}

		hostname := parsed.Hostname()
		port := parsed.Port()
		if port == "" {
			port = "80"
		}

		requestURI := parsed.RequestURI()
		if requestURI == "" {
			requestURI = "/json"
		}

		targets = append(targets, target{
			raw:     raw,
			addr:    net.JoinHostPort(hostname, port),
			host:    parsed.Host,
			request: requestURI,
		})
	}

	if len(targets) == 0 {
		return nil, errors.New("no target URLs")
	}
	return targets, nil
}

func parseConnectionTargets(value string, fallback int) ([]int, error) {
	if strings.TrimSpace(value) == "" {
		if fallback <= 0 {
			return nil, fmt.Errorf("connection count must be positive")
		}
		return []int{fallback}, nil
	}

	fields := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r'
	})
	targets := make([]int, 0, len(fields))
	previous := 0
	for _, field := range fields {
		target, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || target <= 0 {
			return nil, fmt.Errorf("invalid connection target %q", field)
		}
		if target < previous {
			return nil, fmt.Errorf("connection target %d is lower than previous target %d", target, previous)
		}
		if target == previous {
			continue
		}
		targets = append(targets, target)
		previous = target
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("no connection targets")
	}
	return targets, nil
}

func parsePayloadSizes(value string) ([]int, error) {
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}

	fields := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r'
	})
	sizes := make([]int, 0, len(fields))
	seen := make(map[int]bool, len(fields))
	for _, field := range fields {
		size, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || size < 0 {
			return nil, fmt.Errorf("invalid payload size %q", field)
		}
		if seen[size] {
			continue
		}
		seen[size] = true
		sizes = append(sizes, size)
	}
	return sizes, nil
}

func openConnections(ctx context.Context, targetConnections int, targetConnectionRate int, targets []target, payload string, active *atomic.Int64, peak *atomic.Int64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, latencyCh chan<- latencySample, registerCh chan<- *clientConn, wg *sync.WaitGroup, marker *atomic.Value, errorLog *errorLogger) {
	if targetConnections <= 0 {
		return
	}

	opened := int(active.Load())
	if opened >= targetConnections {
		return
	}

	var carry float64
	tickInterval := time.Second
	perTick := float64(targetConnectionRate) * tickInterval.Seconds()
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	stallTimeout := 30 * time.Second
	var launchedAllAt time.Time

	launchBatch := func() {
		carry += perTick
		batch := int(math.Floor(carry))
		carry -= float64(batch)
		if batch < 1 {
			batch = 1
		}

		for i := 0; i < batch && opened < targetConnections; i++ {
			client := &clientConn{
				id:       opened,
				target:   targets[opened%len(targets)],
				payload:  payload,
				sendCh:   make(chan requestDispatch, 1),
				active:   active,
				peak:     peak,
				sent:     sent,
				received: received,
				errors:   errorsCount,
				latency:  latencyCh,
				register: registerCh,
				marker:   marker,
				errorLog: errorLog,
			}

			opened++
			wg.Add(1)
			go func() {
				defer wg.Done()
				client.run(ctx)
			}()
		}
	}

	for int(active.Load()) < targetConnections {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if opened < targetConnections {
				launchBatch()
				if opened >= targetConnections {
					launchedAllAt = time.Now()
				}
			} else if launchedAllAt.IsZero() {
				launchedAllAt = time.Now()
			} else if time.Since(launchedAllAt) >= stallTimeout {
				activeNow := active.Load()
				logDispatchError(errorLog, marker, "ramp", 0, fmt.Errorf("connection ramp stalled at %d/%d active connections after launching %d attempts", activeNow, targetConnections, opened))
				return
			}
		}
	}
}

func sendRequests(ctx context.Context, start time.Time, end time.Time, requestsPerSecond int, stageIndex int, payload string, rampRPS bool, requestID *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, activeMu *sync.Mutex, activeConns *[]*clientConn, marker *atomic.Value, errorLog *errorLogger) {
	if requestsPerSecond <= 0 {
		waitUntil(ctx, end)
		return
	}

	tickInterval := 100 * time.Millisecond
	totalTicks := int(end.Sub(start) / tickInterval)
	totalSeconds := end.Sub(start).Seconds()
	rpsStep := float64(requestsPerSecond) / totalSeconds
	var nextConn int
	var carry float64
	dispatch := func(targetRPS float64) {
		perTick := targetRPS * tickInterval.Seconds()
		carry += perTick
		batch := int(math.Floor(carry))
		carry -= float64(batch)

		for i := 0; i < batch; i++ {
			activeMu.Lock()
			if len(*activeConns) == 0 {
				activeMu.Unlock()
				errorsCount.Add(1)
				logDispatchError(errorLog, marker, "dispatch", 0, errors.New("no active connections"))
				continue
			}

			conn := nextIdleConn(*activeConns, &nextConn)
			activeMu.Unlock()
			if conn == nil {
				dispatchMisses.Add(1)
				continue
			}

			if conn.dead.Load() {
				conn.inFlight.Store(false)
				errorsCount.Add(1)
				logDispatchError(errorLog, marker, "dispatch", 0, fmt.Errorf("connection %d is closed", conn.id))
				continue
			}

			id := requestID.Add(1)
			select {
			case conn.sendCh <- requestDispatch{id: id, stageIndex: stageIndex, payload: payload}:
			default:
				conn.inFlight.Store(false)
				dispatchMisses.Add(1)
			}
		}
	}

	for tick := 1; tick <= totalTicks; tick++ {
		tickTime := start.Add(time.Duration(tick) * tickInterval)
		if waitUntil(ctx, tickTime) != nil {
			return
		}

		elapsedSeconds := math.Ceil(tickTime.Sub(start).Seconds())
		targetRPS := float64(requestsPerSecond)
		if rampRPS {
			targetRPS = math.Min(float64(requestsPerSecond), rpsStep*elapsedSeconds)
		}
		current := currentMarker(marker)
		current.TargetRPS = int(math.Round(targetRPS))
		current.PayloadBytes = len(payload)
		marker.Store(current)
		dispatch(targetRPS)
	}
}

func checksum(payload string) uint32 {
	var value uint32 = 2166136261
	for index := 0; index < len(payload); index++ {
		value ^= uint32(payload[index])
		value *= 16777619
	}
	return value
}

func nextIdleConn(conns []*clientConn, nextConn *int) *clientConn {
	if len(conns) == 0 {
		return nil
	}

	for attempts := 0; attempts < len(conns); attempts++ {
		conn := conns[*nextConn%len(conns)]
		*nextConn++
		if conn.dead.Load() {
			continue
		}
		if conn.inFlight.CompareAndSwap(false, true) {
			return conn
		}
	}

	return nil
}

func waitForInFlight(ctx context.Context, activeMu *sync.Mutex, activeConns *[]*clientConn) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		activeMu.Lock()
		inFlight := false
		for _, conn := range *activeConns {
			if conn.inFlight.Load() {
				inFlight = true
				break
			}
		}
		activeMu.Unlock()

		if !inFlight {
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func logDispatchError(errorLog *errorLogger, marker *atomic.Value, operation string, requestID uint64, err error) {
	if errorLog == nil || err == nil {
		return
	}
	current := currentMarker(marker)
	errorLog.write(loadgenErrorSample{
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
		ElapsedSeconds: int64(time.Since(errorLog.startedAt).Seconds()),
		Phase:          current.Phase,
		StageIndex:     current.StageIndex,
		TargetConns:    current.TargetConns,
		PayloadBytes:   current.PayloadBytes,
		Operation:      operation,
		ConnectionID:   -1,
		RequestID:      requestID,
		Error:          err.Error(),
	})
}

func sampleMetrics(ctx context.Context, startedAt time.Time, marker *atomic.Value, file *os.File, active *atomic.Int64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	encoder := json.NewEncoder(file)
	var lastSent uint64
	var lastReceived uint64
	var lastErrors uint64
	var lastDispatchMisses uint64
	drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, active, sent, received, errorsCount, dispatchMisses, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)

	for {
		select {
		case <-ctx.Done():
			drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, active, sent, received, errorsCount, dispatchMisses, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)
			return
		case now := <-ticker.C:
			drainAndWriteSample(now.UTC(), startedAt, currentMarker(marker), encoder, active, sent, received, errorsCount, dispatchMisses, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)
		}
	}
}

func drainAndWriteSample(now time.Time, startedAt time.Time, marker runMarker, encoder *json.Encoder, active *atomic.Int64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, lastSent *uint64, lastReceived *uint64, lastErrors *uint64, lastDispatchMisses *uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
	latencies := make([]latencySample, 0, 4096)
	for {
		select {
		case value := <-latencyCh:
			latencies = append(latencies, value)
		default:
			if len(latencies) > 0 {
				recordLatencies(latencies)
			}

			currentSent := sent.Load()
			currentReceived := received.Load()
			currentErrors := errorsCount.Load()
			currentDispatchMisses := dispatchMisses.Load()

			sample := metricSample{
				Timestamp:               now.Format(time.RFC3339),
				ElapsedSeconds:          int64(now.Sub(startedAt).Seconds()),
				Phase:                   marker.Phase,
				StageIndex:              marker.StageIndex,
				TargetConns:             marker.TargetConns,
				TargetRPS:               marker.TargetRPS,
				PayloadBytes:            marker.PayloadBytes,
				ActiveConns:             active.Load(),
				Sent:                    currentSent,
				Received:                currentReceived,
				Errors:                  currentErrors,
				DispatchMisses:          currentDispatchMisses,
				SentPerSecond:           currentSent - *lastSent,
				ReceivedPerSecond:       currentReceived - *lastReceived,
				ErrorsPerSecond:         currentErrors - *lastErrors,
				DispatchMissesPerSecond: currentDispatchMisses - *lastDispatchMisses,
				P50LatencyMS:            percentile(latencyValues(latencies), 50),
				P90LatencyMS:            percentile(latencyValues(latencies), 90),
				P99LatencyMS:            percentile(latencyValues(latencies), 99),
				MaxLatencyMS:            percentile(latencyValues(latencies), 100),
			}

			_ = encoder.Encode(sample)
			*lastSent = currentSent
			*lastReceived = currentReceived
			*lastErrors = currentErrors
			*lastDispatchMisses = currentDispatchMisses
			return
		}
	}
}

func latencyValues(samples []latencySample) []float64 {
	values := make([]float64, 0, len(samples))
	for _, sample := range samples {
		values = append(values, sample.ms)
	}
	return values
}

func percentile(values []float64, pct float64) float64 {
	if len(values) == 0 {
		return 0
	}

	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	if pct >= 100 {
		return sorted[len(sorted)-1]
	}

	position := (pct / 100) * float64(len(sorted)-1)
	lower := int(math.Floor(position))
	upper := int(math.Ceil(position))
	if lower == upper {
		return sorted[lower]
	}

	weight := position - float64(lower)
	return sorted[lower]*(1-weight) + sorted[upper]*weight
}

func updatePeak(peak *atomic.Int64, value int64) {
	for {
		current := peak.Load()
		if value <= current || peak.CompareAndSwap(current, value) {
			return
		}
	}
}

func currentMarker(marker *atomic.Value) runMarker {
	if marker == nil {
		return runMarker{Phase: "unknown", StageIndex: -1}
	}
	value, ok := marker.Load().(runMarker)
	if !ok || value.Phase == "" {
		return runMarker{Phase: "unknown", StageIndex: -1}
	}
	return value
}

func waitPhase(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return nil
	}

	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func waitUntil(ctx context.Context, target time.Time) error {
	duration := time.Until(target)
	if duration <= 0 {
		return nil
	}

	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func writeJSON(path string, value any) {
	file, err := os.Create(path)
	if err != nil {
		fatalf("create %s: %v", path, err)
	}
	defer file.Close()

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		fatalf("write %s: %v", path, err)
	}
}

func (logger *errorLogger) write(sample loadgenErrorSample) {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	_ = logger.encoder.Encode(sample)
}

func fatalf(format string, args ...any) {
	err := fmt.Errorf(format, args...)
	if !errors.Is(err, context.Canceled) {
		fmt.Fprintf(os.Stderr, "loadgen: %v\n", err)
	}
	os.Exit(1)
}
