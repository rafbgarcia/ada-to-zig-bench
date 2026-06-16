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

const maxErrorSamples = 50_000

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
	ElapsedMS               int64   `json:"elapsed_ms"`
	WorkMode                string  `json:"work_mode"`
	Phase                   string  `json:"phase"`
	StageIndex              int     `json:"stage_index"`
	TargetRPS               int     `json:"target_requests_per_second"`
	PayloadBytes            int     `json:"payload_bytes"`
	InFlight                int64   `json:"in_flight"`
	Scheduled               uint64  `json:"scheduled"`
	Dispatched              uint64  `json:"dispatched"`
	Sent                    uint64  `json:"sent"`
	Received                uint64  `json:"received"`
	Errors                  uint64  `json:"errors"`
	DispatchMisses          uint64  `json:"dispatch_misses"`
	ScheduledPerSecond      uint64  `json:"scheduled_per_second"`
	DispatchedPerSecond     uint64  `json:"dispatched_per_second"`
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
	WorkMode                string         `json:"work_mode"`
	ClientConnections       int            `json:"client_connections"`
	ConnectionRetries       int            `json:"connection_retries"`
	ConnectionRetryDelayMS  int64          `json:"connection_retry_delay_ms"`
	PayloadBytes            int            `json:"payload_bytes"`
	PayloadSweepBytes       []int          `json:"payload_sweep_bytes"`
	PayloadSweepSeconds     int            `json:"payload_sweep_seconds"`
	TargetRequestsPerSecond int            `json:"target_requests_per_second"`
	TargetMessagesPerSecond int            `json:"target_messages_per_second"`
	StartedAt               string         `json:"started_at"`
	FinishedAt              string         `json:"finished_at"`
	TotalScheduled          uint64         `json:"total_scheduled"`
	TotalDispatched         uint64         `json:"total_dispatched"`
	TotalSent               uint64         `json:"total_sent"`
	TotalReceived           uint64         `json:"total_received"`
	TotalErrors             uint64         `json:"total_errors"`
	TotalConnectionAttempts uint64         `json:"total_connection_attempts"`
	TotalConnectionRetries  uint64         `json:"total_connection_retries"`
	TotalConnectionFailures uint64         `json:"total_connection_failures"`
	LoadgenErrorSamples     uint64         `json:"loadgen_error_samples"`
	LoadgenErrorsDropped    uint64         `json:"loadgen_errors_dropped"`
	TotalDispatchMisses     uint64         `json:"total_dispatch_misses"`
	Complete                bool           `json:"complete"`
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
	WorkMode                string  `json:"work_mode"`
	ClientConnections       int     `json:"client_connections"`
	TargetRequestsPerSecond int     `json:"target_requests_per_second"`
	TargetRequests          uint64  `json:"target_requests"`
	PayloadBytes            int     `json:"payload_bytes"`
	StartedAt               string  `json:"started_at"`
	SendStartedAt           string  `json:"send_started_at"`
	DispatchFinishedAt      string  `json:"dispatch_finished_at"`
	SendFinishedAt          string  `json:"send_finished_at"`
	FinishedAt              string  `json:"finished_at"`
	SendSeconds             int     `json:"send_seconds"`
	DrainSeconds            int     `json:"drain_seconds"`
	ElapsedSeconds          int     `json:"elapsed_seconds"`
	Scheduled               uint64  `json:"scheduled"`
	Dispatched              uint64  `json:"dispatched"`
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
	id            int
	target        target
	payload       string
	sendCh        chan requestDispatch
	dead          atomic.Bool
	conn          net.Conn
	reader        *bufio.Reader
	active        *atomic.Int64
	sent          *atomic.Uint64
	received      *atomic.Uint64
	errors        *atomic.Uint64
	inFlightCount *atomic.Int64
	inFlight      atomic.Bool
	latency       chan<- latencySample
	register      chan<- *clientConn
	marker        *atomic.Value
	errorLog      *errorLogger

	connectionRetries       int
	connectionRetryDelay    time.Duration
	connectionAttempts      *atomic.Uint64
	connectionRetryAttempts *atomic.Uint64
	connectionFailures      *atomic.Uint64
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
	WorkMode     string
	ClientConns  int
	TargetRPS    int
	PayloadBytes int
}

type workMode string

const (
	workModeOpenLoop  workMode = "open-loop"
	workModeFixedWork workMode = "fixed-work"
)

type sendResult struct {
	Scheduled  uint64
	Dispatched uint64
	StartedAt  time.Time
	FinishedAt time.Time
}

type loadgenErrorSample struct {
	Timestamp      string `json:"ts"`
	ElapsedSeconds int64  `json:"elapsed_seconds"`
	Phase          string `json:"phase"`
	StageIndex     int    `json:"stage_index"`
	ClientConns    int    `json:"client_connections"`
	PayloadBytes   int    `json:"payload_bytes"`
	Operation      string `json:"operation"`
	ConnectionID   int    `json:"connection_id"`
	Target         string `json:"target"`
	RequestID      uint64 `json:"request_id,omitempty"`
	Attempt        int    `json:"attempt,omitempty"`
	MaxRetries     int    `json:"max_retries,omitempty"`
	RetryAfterMS   int64  `json:"retry_after_ms,omitempty"`
	Terminal       bool   `json:"terminal,omitempty"`
	Error          string `json:"error"`
}

type errorLogger struct {
	mu        sync.Mutex
	encoder   *json.Encoder
	startedAt time.Time
	written   uint64
	dropped   uint64
}

func main() {
	var targetURL string
	var targetURLs string
	var clientConnections int
	var payloadBytes int
	var payloadSweepBytesRaw string
	var payloadSweepSeconds int
	var requestsPerSecond int
	var workModeRaw string
	var connectionRetries int
	var connectionRetryDelay time.Duration
	var outputDir string

	flag.StringVar(&targetURL, "url", "http://127.0.0.1:8080/json", "HTTP JSON URL")
	flag.StringVar(&targetURLs, "urls", "", "comma-separated HTTP JSON URLs; overrides --url when set")
	flag.IntVar(&clientConnections, "client-connections", 8192, "persistent HTTP client connections kept by the load generator")
	flag.IntVar(&payloadBytes, "payload-bytes", 256, "payload string size in bytes")
	flag.StringVar(&payloadSweepBytesRaw, "payload-sweep-bytes", "", "comma- or space-separated payload sizes to send; defaults to --payload-bytes")
	flag.IntVar(&payloadSweepSeconds, "payload-sweep-seconds", 10, "seconds to send each payload size in --payload-sweep-bytes")
	flag.IntVar(&requestsPerSecond, "requests-per-second", 100_000, "global target requests per second")
	flag.StringVar(&workModeRaw, "work-mode", string(workModeOpenLoop), "request work mode: open-loop drops missed dispatch slots; fixed-work keeps dispatching until every scheduled slot is sent")
	flag.IntVar(&connectionRetries, "connection-retries", 3, "failed connection dial/warmup retries before a connection slot is marked failed")
	flag.DurationVar(&connectionRetryDelay, "connection-retry-delay", time.Second, "delay between failed connection dial/warmup retries")
	flag.StringVar(&outputDir, "output", "runs/manual", "output run directory")
	flag.Parse()

	payloadSweepBytes, err := parsePayloadSizes(payloadSweepBytesRaw)
	if err != nil {
		fatalf("parse payload sweep sizes: %v", err)
	}
	if len(payloadSweepBytes) == 0 {
		payloadSweepBytes = []int{payloadBytes}
	}
	mode, err := parseWorkMode(workModeRaw)
	if err != nil {
		fatalf("parse work mode: %v", err)
	}
	if clientConnections <= 0 || payloadBytes < 0 || payloadSweepSeconds <= 0 || requestsPerSecond <= 0 || connectionRetries < 0 || connectionRetryDelay < 0 {
		fatalf("invalid arguments")
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
	var sent atomic.Uint64
	var received atomic.Uint64
	var errorsCount atomic.Uint64
	var scheduled atomic.Uint64
	var dispatched atomic.Uint64
	var dispatchMisses atomic.Uint64
	var requestID atomic.Uint64
	var inFlight atomic.Int64
	var connectionAttempts atomic.Uint64
	var connectionRetryAttempts atomic.Uint64
	var connectionFailures atomic.Uint64

	latencyCh := make(chan latencySample, 1_000_000)
	registerCh := make(chan *clientConn, clientConnections)
	marker := atomic.Value{}
	marker.Store(runMarker{Phase: "payload_sweep", StageIndex: 0, WorkMode: string(mode), ClientConns: clientConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadSweepBytes[0]})

	var activeMu sync.Mutex
	activeConns := make([]*clientConn, 0, clientConnections)
	go func() {
		for conn := range registerCh {
			activeMu.Lock()
			activeConns = append(activeConns, conn)
			activeMu.Unlock()
		}
	}()

	var wg sync.WaitGroup

	openClientConnections(runCtx, clientConnections, targets, payload, connectionRetries, connectionRetryDelay, &active, &sent, &received, &errorsCount, &inFlight, &connectionAttempts, &connectionRetryAttempts, &connectionFailures, latencyCh, registerCh, &wg, &marker, errorLog)
	waitForClientSetup(runCtx, clientConnections, &activeMu, &activeConns, &active, &connectionFailures)

	measurementStartedAt := time.Now().UTC()
	var metricsWG sync.WaitGroup
	latencyCapacity := min(requestsPerSecond*payloadSweepSeconds*len(payloadSweepBytes), 10_000_000)
	allLatencies := make([]float64, 0, latencyCapacity)
	var allLatenciesMu sync.Mutex
	metricsWG.Add(1)
	go func() {
		defer metricsWG.Done()
		sampleMetrics(runCtx, measurementStartedAt, &marker, metricsFile, &inFlight, &scheduled, &dispatched, &sent, &received, &errorsCount, &dispatchMisses, latencyCh, func(values []latencySample) {
			allLatenciesMu.Lock()
			for _, value := range values {
				allLatencies = append(allLatencies, value.ms)
			}
			allLatenciesMu.Unlock()
		})
	}()

	stages := make([]stageSummary, 0, len(payloadSweepBytes))
	for _, sweepPayloadBytes := range payloadSweepBytes {
		if runCtx.Err() != nil {
			break
		}

		stageIndex := len(stages)
		sweepPayload := strings.Repeat("x", sweepPayloadBytes)
		stageStarted := time.Now().UTC()
		stageScheduledStart := scheduled.Load()
		stageDispatchedStart := dispatched.Load()
		stageSentStart := sent.Load()
		stageReceivedStart := received.Load()
		stageErrorsStart := errorsCount.Load()
		stageDispatchMissesStart := dispatchMisses.Load()
		allLatenciesMu.Lock()
		stageLatencyStart := len(allLatencies)
		allLatenciesMu.Unlock()

		marker.Store(runMarker{Phase: "payload_sweep", StageIndex: stageIndex, WorkMode: string(mode), ClientConns: clientConnections, TargetRPS: requestsPerSecond, PayloadBytes: sweepPayloadBytes})
		sendStartedAt := time.Now().UTC()
		sendFinishedAt := sendStartedAt.Add(time.Duration(payloadSweepSeconds) * time.Second)
		sendResult := sendRequests(runCtx, sendStartedAt, sendFinishedAt, requestsPerSecond, stageIndex, sweepPayload, mode, &requestID, &scheduled, &dispatched, &errorsCount, &dispatchMisses, &activeMu, &activeConns, &marker, errorLog)
		waitForInFlight(runCtx, &activeMu, &activeConns)
		stageEndedAt := time.Now().UTC()
		finishedAt := time.Now().UTC()

		allLatenciesMu.Lock()
		stageLatencies := append([]float64(nil), allLatencies[stageLatencyStart:]...)
		allLatenciesMu.Unlock()
		stages = append(stages, stageSummary{
			Index:                   stageIndex,
			Phase:                   "payload_sweep",
			WorkMode:                string(mode),
			ClientConnections:       clientConnections,
			TargetRequestsPerSecond: requestsPerSecond,
			TargetRequests:          targetRequestCount(requestsPerSecond, payloadSweepSeconds),
			PayloadBytes:            sweepPayloadBytes,
			StartedAt:               stageStarted.Format(time.RFC3339),
			SendStartedAt:           sendStartedAt.Format(time.RFC3339),
			DispatchFinishedAt:      sendResult.FinishedAt.Format(time.RFC3339),
			SendFinishedAt:          stageEndedAt.Format(time.RFC3339),
			FinishedAt:              finishedAt.Format(time.RFC3339),
			SendSeconds:             ceilSeconds(sendResult.FinishedAt.Sub(sendResult.StartedAt)),
			DrainSeconds:            ceilSeconds(stageEndedAt.Sub(sendResult.FinishedAt)),
			ElapsedSeconds:          ceilSeconds(finishedAt.Sub(stageStarted)),
			Scheduled:               scheduled.Load() - stageScheduledStart,
			Dispatched:              dispatched.Load() - stageDispatchedStart,
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

	complete := runCtx.Err() == nil && len(stages) == len(payloadSweepBytes)

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
		WorkMode:                string(mode),
		ClientConnections:       clientConnections,
		ConnectionRetries:       connectionRetries,
		ConnectionRetryDelayMS:  connectionRetryDelay.Milliseconds(),
		PayloadBytes:            payloadBytes,
		PayloadSweepBytes:       payloadSweepBytes,
		PayloadSweepSeconds:     payloadSweepSeconds,
		TargetRequestsPerSecond: requestsPerSecond,
		TargetMessagesPerSecond: requestsPerSecond,
		StartedAt:               startedAt.Format(time.RFC3339),
		FinishedAt:              time.Now().UTC().Format(time.RFC3339),
		TotalScheduled:          scheduled.Load(),
		TotalDispatched:         dispatched.Load(),
		TotalSent:               sent.Load(),
		TotalReceived:           received.Load(),
		TotalErrors:             errorsCount.Load(),
		TotalConnectionAttempts: connectionAttempts.Load(),
		TotalConnectionRetries:  connectionRetryAttempts.Load(),
		TotalConnectionFailures: connectionFailures.Load(),
		LoadgenErrorSamples:     errorLog.samples(),
		LoadgenErrorsDropped:    errorLog.droppedSamples(),
		TotalDispatchMisses:     dispatchMisses.Load(),
		Complete:                complete,
		Success:                 complete,
		P50LatencyMS:            overallP50,
		P90LatencyMS:            overallP90,
		P99LatencyMS:            overallP99,
		MaxLatencyMS:            overallMax,
		Stages:                  stages,
	}

	writeJSON(filepath.Join(outputDir, "summary.json"), s)
	fmt.Printf("wrote run data to %s\n", outputDir)
}

func (c *clientConn) run(ctx context.Context) {
	defer c.dead.Store(true)

	maxAttempts := c.connectionRetries + 1
	if maxAttempts < 1 {
		maxAttempts = 1
	}

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if ctx.Err() != nil {
			return
		}
		if attempt > 1 && c.connectionRetryAttempts != nil {
			c.connectionRetryAttempts.Add(1)
		}
		if c.connectionAttempts != nil {
			c.connectionAttempts.Add(1)
		}

		dialer := net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
		conn, err := dialer.DialContext(ctx, "tcp", c.target.addr)
		if err != nil {
			c.recordConnectionAttemptError("dial", attempt, maxAttempts, err)
			if attempt == maxAttempts {
				return
			}
			if waitPhase(ctx, c.connectionRetryDelay) != nil {
				return
			}
			continue
		}

		c.conn = conn
		c.reader = bufio.NewReaderSize(conn, 4096)
		if tcpConn, ok := conn.(*net.TCPConn); ok {
			_ = tcpConn.SetKeepAlive(true)
			_ = tcpConn.SetKeepAlivePeriod(30 * time.Second)
		}

		if err := c.warmup(); err != nil {
			_ = conn.Close()
			c.conn = nil
			c.reader = nil
			c.recordConnectionAttemptError("warmup", attempt, maxAttempts, err)
			if attempt == maxAttempts {
				return
			}
			if waitPhase(ctx, c.connectionRetryDelay) != nil {
				return
			}
			continue
		}

		break
	}

	if c.conn == nil {
		return
	}

	c.register <- c
	c.active.Add(1)
	defer c.active.Add(-1)
	defer c.conn.Close()

	for {
		select {
		case <-ctx.Done():
			return
		case request := <-c.sendCh:
			err := c.send(request)
			if err != nil {
				c.dead.Store(true)
				c.inFlight.Store(false)
				if c.inFlightCount != nil {
					c.inFlightCount.Add(-1)
				}
				c.errors.Add(1)
				c.logError("request", request.id, err)
				return
			}
			c.inFlight.Store(false)
			if c.inFlightCount != nil {
				c.inFlightCount.Add(-1)
			}
		}
	}
}

func (c *clientConn) recordConnectionAttemptError(operation string, attempt int, maxAttempts int, err error) {
	c.errors.Add(1)
	terminal := attempt >= maxAttempts
	if terminal && c.connectionFailures != nil {
		c.connectionFailures.Add(1)
	}
	c.logConnectionError(operation, attempt, maxAttempts-1, terminal, err)
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
		ClientConns:    marker.ClientConns,
		PayloadBytes:   marker.PayloadBytes,
		Operation:      operation,
		ConnectionID:   c.id,
		Target:         c.target.raw,
		RequestID:      requestID,
		Error:          err.Error(),
	})
}

func (c *clientConn) logConnectionError(operation string, attempt int, maxRetries int, terminal bool, err error) {
	if c.errorLog == nil || err == nil {
		return
	}
	marker := currentMarker(c.marker)
	retryAfterMS := int64(0)
	if !terminal && c.connectionRetryDelay > 0 {
		retryAfterMS = c.connectionRetryDelay.Milliseconds()
	}
	c.errorLog.write(loadgenErrorSample{
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
		ElapsedSeconds: int64(time.Since(c.errorLog.startedAt).Seconds()),
		Phase:          marker.Phase,
		StageIndex:     marker.StageIndex,
		ClientConns:    marker.ClientConns,
		PayloadBytes:   marker.PayloadBytes,
		Operation:      operation,
		ConnectionID:   c.id,
		Target:         c.target.raw,
		Attempt:        attempt,
		MaxRetries:     maxRetries,
		RetryAfterMS:   retryAfterMS,
		Terminal:       terminal,
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

func parseWorkMode(value string) (workMode, error) {
	switch strings.TrimSpace(strings.ToLower(value)) {
	case "", string(workModeOpenLoop), "openloop", "open_loop":
		return workModeOpenLoop, nil
	case string(workModeFixedWork), "fixed", "fixed_work":
		return workModeFixedWork, nil
	default:
		return "", fmt.Errorf("expected %q or %q", workModeOpenLoop, workModeFixedWork)
	}
}

func targetRequestCount(requestsPerSecond int, seconds int) uint64 {
	if requestsPerSecond <= 0 || seconds <= 0 {
		return 0
	}
	return uint64(requestsPerSecond) * uint64(seconds)
}

func ceilSeconds(duration time.Duration) int {
	if duration <= 0 {
		return 0
	}
	return int(math.Ceil(duration.Seconds()))
}

func ratePerSecond(delta uint64, seconds float64) uint64 {
	if delta == 0 || seconds <= 0 {
		return 0
	}
	return uint64(math.Round(float64(delta) / seconds))
}

func openClientConnections(ctx context.Context, clientConnections int, targets []target, payload string, connectionRetries int, connectionRetryDelay time.Duration, active *atomic.Int64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, inFlight *atomic.Int64, connectionAttempts *atomic.Uint64, connectionRetryAttempts *atomic.Uint64, connectionFailures *atomic.Uint64, latencyCh chan<- latencySample, registerCh chan<- *clientConn, wg *sync.WaitGroup, marker *atomic.Value, errorLog *errorLogger) {
	for index := 0; index < clientConnections; index++ {
		client := &clientConn{
			id:            index,
			target:        targets[index%len(targets)],
			payload:       payload,
			sendCh:        make(chan requestDispatch, 1),
			active:        active,
			sent:          sent,
			received:      received,
			errors:        errorsCount,
			inFlightCount: inFlight,
			latency:       latencyCh,
			register:      registerCh,
			marker:        marker,
			errorLog:      errorLog,

			connectionRetries:       connectionRetries,
			connectionRetryDelay:    connectionRetryDelay,
			connectionAttempts:      connectionAttempts,
			connectionRetryAttempts: connectionRetryAttempts,
			connectionFailures:      connectionFailures,
		}

		wg.Add(1)
		go func() {
			defer wg.Done()
			client.run(ctx)
		}()
	}
}

func sendRequests(ctx context.Context, start time.Time, end time.Time, requestsPerSecond int, stageIndex int, payload string, mode workMode, requestID *atomic.Uint64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, activeMu *sync.Mutex, activeConns *[]*clientConn, marker *atomic.Value, errorLog *errorLogger) sendResult {
	result := sendResult{StartedAt: start, FinishedAt: time.Now().UTC()}
	if requestsPerSecond <= 0 {
		waitUntil(ctx, end)
		result.FinishedAt = time.Now().UTC()
		return result
	}

	tickInterval := 100 * time.Millisecond
	totalTicks := int(end.Sub(start) / tickInterval)
	var nextConn int
	var carry float64
	dispatchOne := func() bool {
		activeMu.Lock()
		if len(*activeConns) == 0 {
			activeMu.Unlock()
			errorsCount.Add(1)
			logDispatchError(errorLog, marker, "dispatch", 0, errors.New("no active connections"))
			return false
		}

		conn := nextIdleConn(*activeConns, &nextConn)
		activeMu.Unlock()
		if conn == nil {
			dispatchMisses.Add(1)
			return false
		}
		if conn.inFlightCount != nil {
			conn.inFlightCount.Add(1)
		}

		if conn.dead.Load() {
			conn.inFlight.Store(false)
			if conn.inFlightCount != nil {
				conn.inFlightCount.Add(-1)
			}
			errorsCount.Add(1)
			logDispatchError(errorLog, marker, "dispatch", 0, fmt.Errorf("connection %d is closed", conn.id))
			return false
		}

		id := requestID.Add(1)
		select {
		case conn.sendCh <- requestDispatch{id: id, stageIndex: stageIndex, payload: payload}:
			dispatched.Add(1)
			result.Dispatched++
			return true
		default:
			conn.inFlight.Store(false)
			if conn.inFlightCount != nil {
				conn.inFlightCount.Add(-1)
			}
			dispatchMisses.Add(1)
			return false
		}
	}
	dispatchOpenLoop := func(targetRPS float64) {
		perTick := targetRPS * tickInterval.Seconds()
		carry += perTick
		batch := int(math.Floor(carry))
		carry -= float64(batch)

		for i := 0; i < batch; i++ {
			scheduled.Add(1)
			result.Scheduled++
			dispatchOne()
		}
	}
	dispatchFixedWork := func(targetRPS float64) bool {
		perTick := targetRPS * tickInterval.Seconds()
		carry += perTick
		batch := int(math.Floor(carry))
		carry -= float64(batch)

		for i := 0; i < batch; i++ {
			scheduled.Add(1)
			result.Scheduled++
		}

		for result.Dispatched < result.Scheduled {
			if ctx.Err() != nil {
				return false
			}
			if dispatchOne() {
				continue
			}
			if waitPhase(ctx, 10*time.Millisecond) != nil {
				return false
			}
		}
		return true
	}

	for tick := 1; tick <= totalTicks; tick++ {
		tickTime := start.Add(time.Duration(tick) * tickInterval)
		if waitUntil(ctx, tickTime) != nil {
			result.FinishedAt = time.Now().UTC()
			return result
		}

		targetRPS := float64(requestsPerSecond)
		current := currentMarker(marker)
		current.TargetRPS = int(math.Round(targetRPS))
		current.PayloadBytes = len(payload)
		marker.Store(current)
		if mode == workModeFixedWork {
			if !dispatchFixedWork(targetRPS) {
				result.FinishedAt = time.Now().UTC()
				return result
			}
		} else {
			dispatchOpenLoop(targetRPS)
		}
	}

	result.FinishedAt = time.Now().UTC()
	return result
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

func waitForClientSetup(ctx context.Context, clientConnections int, activeMu *sync.Mutex, activeConns *[]*clientConn, active *atomic.Int64, connectionFailures *atomic.Uint64) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		activeMu.Lock()
		registered := len(*activeConns)
		activeMu.Unlock()

		if registered >= clientConnections || int(active.Load())+int(connectionFailures.Load()) >= clientConnections {
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
		ClientConns:    current.ClientConns,
		PayloadBytes:   current.PayloadBytes,
		Operation:      operation,
		ConnectionID:   -1,
		RequestID:      requestID,
		Error:          err.Error(),
	})
}

func sampleMetrics(ctx context.Context, startedAt time.Time, marker *atomic.Value, file *os.File, inFlight *atomic.Int64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	encoder := json.NewEncoder(file)
	lastSampleAt := startedAt
	var lastScheduled uint64
	var lastDispatched uint64
	var lastSent uint64
	var lastReceived uint64
	var lastErrors uint64
	var lastDispatchMisses uint64
	drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)

	for {
		select {
		case <-ctx.Done():
			drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)
			return
		case <-ticker.C:
			drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, latencyCh, recordLatencies)
		}
	}
}

func drainAndWriteSample(now time.Time, startedAt time.Time, marker runMarker, encoder *json.Encoder, inFlight *atomic.Int64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, lastSampleAt *time.Time, lastScheduled *uint64, lastDispatched *uint64, lastSent *uint64, lastReceived *uint64, lastErrors *uint64, lastDispatchMisses *uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
	latencies := make([]latencySample, 0, 4096)
	for {
		select {
		case value := <-latencyCh:
			latencies = append(latencies, value)
		default:
			if len(latencies) > 0 {
				recordLatencies(latencies)
			}

			currentScheduled := scheduled.Load()
			currentDispatched := dispatched.Load()
			currentSent := sent.Load()
			currentReceived := received.Load()
			currentErrors := errorsCount.Load()
			currentDispatchMisses := dispatchMisses.Load()
			deltaSeconds := math.Max(now.Sub(*lastSampleAt).Seconds(), 0.001)

			sample := metricSample{
				Timestamp:               now.Format(time.RFC3339Nano),
				ElapsedSeconds:          int64(now.Sub(startedAt).Seconds()),
				ElapsedMS:               now.Sub(startedAt).Milliseconds(),
				WorkMode:                marker.WorkMode,
				Phase:                   marker.Phase,
				StageIndex:              marker.StageIndex,
				TargetRPS:               marker.TargetRPS,
				PayloadBytes:            marker.PayloadBytes,
				InFlight:                inFlight.Load(),
				Scheduled:               currentScheduled,
				Dispatched:              currentDispatched,
				Sent:                    currentSent,
				Received:                currentReceived,
				Errors:                  currentErrors,
				DispatchMisses:          currentDispatchMisses,
				ScheduledPerSecond:      ratePerSecond(currentScheduled-*lastScheduled, deltaSeconds),
				DispatchedPerSecond:     ratePerSecond(currentDispatched-*lastDispatched, deltaSeconds),
				SentPerSecond:           ratePerSecond(currentSent-*lastSent, deltaSeconds),
				ReceivedPerSecond:       ratePerSecond(currentReceived-*lastReceived, deltaSeconds),
				ErrorsPerSecond:         ratePerSecond(currentErrors-*lastErrors, deltaSeconds),
				DispatchMissesPerSecond: ratePerSecond(currentDispatchMisses-*lastDispatchMisses, deltaSeconds),
				P50LatencyMS:            percentile(latencyValues(latencies), 50),
				P90LatencyMS:            percentile(latencyValues(latencies), 90),
				P99LatencyMS:            percentile(latencyValues(latencies), 99),
				MaxLatencyMS:            percentile(latencyValues(latencies), 100),
			}

			_ = encoder.Encode(sample)
			*lastSampleAt = now
			*lastScheduled = currentScheduled
			*lastDispatched = currentDispatched
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

func currentMarker(marker *atomic.Value) runMarker {
	if marker == nil {
		return runMarker{Phase: "unknown", StageIndex: -1, WorkMode: string(workModeOpenLoop)}
	}
	value, ok := marker.Load().(runMarker)
	if !ok || value.Phase == "" {
		return runMarker{Phase: "unknown", StageIndex: -1, WorkMode: string(workModeOpenLoop)}
	}
	if value.WorkMode == "" {
		value.WorkMode = string(workModeOpenLoop)
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
	if logger.written >= maxErrorSamples {
		logger.dropped++
		return
	}
	_ = logger.encoder.Encode(sample)
	logger.written++
}

func (logger *errorLogger) samples() uint64 {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	return logger.written
}

func (logger *errorLogger) droppedSamples() uint64 {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	return logger.dropped
}

func fatalf(format string, args ...any) {
	err := fmt.Errorf(format, args...)
	if !errors.Is(err, context.Canceled) {
		fmt.Fprintf(os.Stderr, "loadgen: %v\n", err)
	}
	os.Exit(1)
}
