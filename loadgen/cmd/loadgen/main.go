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
	Timestamp                   string  `json:"ts"`
	ElapsedSeconds              int64   `json:"elapsed_seconds"`
	ElapsedMS                   int64   `json:"elapsed_ms"`
	WorkMode                    string  `json:"work_mode"`
	Phase                       string  `json:"phase"`
	StageIndex                  int     `json:"stage_index"`
	TargetConns                 int     `json:"target_connections"`
	TargetRPS                   int     `json:"target_requests_per_second"`
	PayloadBytes                int     `json:"payload_bytes"`
	ActiveConns                 int64   `json:"active_connections"`
	InFlight                    int64   `json:"in_flight"`
	Scheduled                   uint64  `json:"scheduled"`
	Dispatched                  uint64  `json:"dispatched"`
	Sent                        uint64  `json:"sent"`
	Received                    uint64  `json:"received"`
	Errors                      uint64  `json:"errors"`
	DispatchMisses              uint64  `json:"dispatch_misses"`
	ConnectionAttempts          uint64  `json:"connection_attempts"`
	ConnectionRetries           uint64  `json:"connection_retries"`
	ConnectionFailures          uint64  `json:"connection_failures"`
	ScheduledPerSecond          uint64  `json:"scheduled_per_second"`
	DispatchedPerSecond         uint64  `json:"dispatched_per_second"`
	SentPerSecond               uint64  `json:"sent_per_second"`
	ReceivedPerSecond           uint64  `json:"received_per_second"`
	ErrorsPerSecond             uint64  `json:"errors_per_second"`
	DispatchMissesPerSecond     uint64  `json:"dispatch_misses_per_second"`
	ConnectionAttemptsPerSecond uint64  `json:"connection_attempts_per_second"`
	ConnectionRetriesPerSecond  uint64  `json:"connection_retries_per_second"`
	ConnectionFailuresPerSecond uint64  `json:"connection_failures_per_second"`
	P50LatencyMS                float64 `json:"p50_latency_ms"`
	P90LatencyMS                float64 `json:"p90_latency_ms"`
	P99LatencyMS                float64 `json:"p99_latency_ms"`
	MaxLatencyMS                float64 `json:"max_latency_ms"`
}

type summary struct {
	URL                     string         `json:"url"`
	URLs                    []string       `json:"urls"`
	WorkMode                string         `json:"work_mode"`
	Connections             int            `json:"connections"`
	ConnectionTargets       []int          `json:"connection_targets"`
	ConnectionRetries       int            `json:"connection_retries"`
	ConnectionRetryDelayMS  int64          `json:"connection_retry_delay_ms"`
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
	PeakActiveConnections   int64          `json:"peak_active_connections"`
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
	TargetConnections       int     `json:"target_connections"`
	TargetRequestsPerSecond int     `json:"target_requests_per_second"`
	TargetRequests          uint64  `json:"target_requests"`
	PayloadBytes            int     `json:"payload_bytes"`
	StartedAt               string  `json:"started_at"`
	TrafficStartedAt        string  `json:"traffic_started_at"`
	DispatchFinishedAt      string  `json:"dispatch_finished_at"`
	TrafficFinishedAt       string  `json:"traffic_finished_at"`
	FinishedAt              string  `json:"finished_at"`
	RampSeconds             int     `json:"ramp_seconds"`
	RampReachedTarget       bool    `json:"ramp_reached_target"`
	TrafficRan              bool    `json:"traffic_ran"`
	FailureReason           string  `json:"failure_reason,omitempty"`
	TrafficSeconds          int     `json:"traffic_seconds"`
	StabilizeSeconds        int     `json:"stabilize_seconds"`
	SendSeconds             int     `json:"send_seconds"`
	DrainSeconds            int     `json:"drain_seconds"`
	ElapsedSeconds          int     `json:"elapsed_seconds"`
	ActiveConnections       int64   `json:"active_connections"`
	ConnectionAttempts      uint64  `json:"connection_attempts"`
	ConnectionRetries       uint64  `json:"connection_retries"`
	ConnectionFailures      uint64  `json:"connection_failures"`
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
	peak          *atomic.Int64
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
	TargetConns  int
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
	TargetConns    int    `json:"target_connections"`
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

type connectionRampResult struct {
	TargetReached bool
	FailureReason string
	Launched      int
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
	var connections int
	var connectionTargets string
	var payloadBytes int
	var payloadSweepBytesRaw string
	var payloadSweepSeconds int
	var requestsPerSecond int
	var workModeRaw string
	var targetConnectionRate int
	var connectionRetries int
	var connectionRetryDelay time.Duration
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
	flag.StringVar(&workModeRaw, "work-mode", string(workModeOpenLoop), "request work mode: open-loop drops missed dispatch slots; fixed-work keeps dispatching until every scheduled slot is sent")
	flag.IntVar(&targetConnectionRate, "target-connection-rate", 50_000, "target new HTTP connections per second during ramp")
	flag.IntVar(&connectionRetries, "connection-retries", 3, "failed connection dial/warmup retries before a connection slot is marked failed")
	flag.DurationVar(&connectionRetryDelay, "connection-retry-delay", time.Second, "delay between failed connection dial/warmup retries")
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
	mode, err := parseWorkMode(workModeRaw)
	if err != nil {
		fatalf("parse work mode: %v", err)
	}
	maxConnections := connectionSchedule[len(connectionSchedule)-1]
	if stabilizeSeconds < 0 {
		stabilizeSeconds = settleSeconds
	}
	if maxConnections <= 0 || payloadBytes < 0 || payloadSweepSeconds < 0 || requestsPerSecond <= 0 || targetConnectionRate <= 0 || connectionRetries < 0 || connectionRetryDelay < 0 || baselineSeconds < 0 || settleSeconds < 0 || stabilizeSeconds < 0 || trafficSeconds <= 0 || cooldownSeconds < 0 {
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
	var scheduled atomic.Uint64
	var dispatched atomic.Uint64
	var dispatchMisses atomic.Uint64
	var requestID atomic.Uint64
	var inFlight atomic.Int64
	var connectionAttempts atomic.Uint64
	var connectionRetryAttempts atomic.Uint64
	var connectionFailures atomic.Uint64

	latencyCh := make(chan latencySample, 1_000_000)
	registerCh := make(chan *clientConn, maxConnections)
	marker := atomic.Value{}
	marker.Store(runMarker{Phase: "baseline", StageIndex: -1, WorkMode: string(mode), TargetConns: 0, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})

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
		sampleMetrics(runCtx, startedAt, &marker, metricsFile, &active, &inFlight, &scheduled, &dispatched, &sent, &received, &errorsCount, &dispatchMisses, &connectionAttempts, &connectionRetryAttempts, &connectionFailures, latencyCh, func(values []latencySample) {
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
		stageScheduledStart := scheduled.Load()
		stageDispatchedStart := dispatched.Load()
		stageSentStart := sent.Load()
		stageReceivedStart := received.Load()
		stageErrorsStart := errorsCount.Load()
		stageDispatchMissesStart := dispatchMisses.Load()
		stageConnectionAttemptsStart := connectionAttempts.Load()
		stageConnectionRetriesStart := connectionRetryAttempts.Load()
		stageConnectionFailuresStart := connectionFailures.Load()
		allLatenciesMu.Lock()
		stageLatencyStart := len(allLatencies)
		allLatenciesMu.Unlock()

		marker.Store(runMarker{Phase: "ramp", StageIndex: index, WorkMode: string(mode), TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		rampStartedAt := time.Now().UTC()
		rampResult := openConnections(runCtx, targetConnections, targetConnectionRate, targets, payload, connectionRetries, connectionRetryDelay, &active, &peak, &sent, &received, &errorsCount, &inFlight, &connectionAttempts, &connectionRetryAttempts, &connectionFailures, latencyCh, registerCh, &wg, &marker, errorLog)
		rampSeconds := int(math.Ceil(time.Since(rampStartedAt).Seconds()))
		if !rampResult.TargetReached {
			marker.Store(runMarker{Phase: "ramp_failed", StageIndex: index, WorkMode: string(mode), TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
			cancel()
		}

		if runCtx.Err() == nil {
			marker.Store(runMarker{Phase: "settle", StageIndex: index, WorkMode: string(mode), TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
			if waitPhase(runCtx, time.Duration(settleSeconds)*time.Second) != nil {
				cancel()
			}
		}

		trafficRan := runCtx.Err() == nil
		if trafficRan {
			marker.Store(runMarker{Phase: "traffic", StageIndex: index, WorkMode: string(mode), TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		}
		trafficStartedAt := time.Now().UTC()
		trafficFinishedAt := trafficStartedAt.Add(time.Duration(trafficSeconds) * time.Second)
		sendResult := sendResult{StartedAt: trafficStartedAt, FinishedAt: trafficStartedAt}
		if runCtx.Err() == nil {
			sendResult = sendRequests(runCtx, trafficStartedAt, trafficFinishedAt, requestsPerSecond, index, payload, true, mode, &requestID, &scheduled, &dispatched, &errorsCount, &dispatchMisses, &activeMu, &activeConns, &marker, errorLog)
			waitForInFlight(runCtx, &activeMu, &activeConns)
		}
		trafficEndedAt := time.Now().UTC()

		if runCtx.Err() == nil {
			marker.Store(runMarker{Phase: "stabilize", StageIndex: index, WorkMode: string(mode), TargetConns: targetConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
			if waitPhase(runCtx, time.Duration(stabilizeSeconds)*time.Second) != nil {
				cancel()
			}
		}

		finishedAt := time.Now().UTC()
		allLatenciesMu.Lock()
		stageLatencies := append([]float64(nil), allLatencies[stageLatencyStart:]...)
		allLatenciesMu.Unlock()
		phase := "traffic"
		failureReason := ""
		if !rampResult.TargetReached {
			phase = "ramp_failed"
			failureReason = rampResult.FailureReason
		}

		stages = append(stages, stageSummary{
			Index:                   index,
			Phase:                   phase,
			WorkMode:                string(mode),
			TargetConnections:       targetConnections,
			TargetRequestsPerSecond: requestsPerSecond,
			TargetRequests:          targetRequestCount(requestsPerSecond, trafficSeconds, true),
			PayloadBytes:            payloadBytes,
			StartedAt:               stageStarted.Format(time.RFC3339),
			TrafficStartedAt:        trafficStartedAt.Format(time.RFC3339),
			DispatchFinishedAt:      sendResult.FinishedAt.Format(time.RFC3339),
			TrafficFinishedAt:       trafficEndedAt.Format(time.RFC3339),
			FinishedAt:              finishedAt.Format(time.RFC3339),
			RampSeconds:             rampSeconds,
			RampReachedTarget:       rampResult.TargetReached,
			TrafficRan:              trafficRan,
			FailureReason:           failureReason,
			TrafficSeconds:          trafficSeconds,
			StabilizeSeconds:        stabilizeSeconds,
			SendSeconds:             ceilSeconds(sendResult.FinishedAt.Sub(sendResult.StartedAt)),
			DrainSeconds:            ceilSeconds(trafficEndedAt.Sub(sendResult.FinishedAt)),
			ElapsedSeconds:          ceilSeconds(finishedAt.Sub(stageStarted)),
			ActiveConnections:       active.Load(),
			ConnectionAttempts:      connectionAttempts.Load() - stageConnectionAttemptsStart,
			ConnectionRetries:       connectionRetryAttempts.Load() - stageConnectionRetriesStart,
			ConnectionFailures:      connectionFailures.Load() - stageConnectionFailuresStart,
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

	if runCtx.Err() == nil && len(payloadSweepBytes) > 0 {
		for _, sweepPayloadBytes := range payloadSweepBytes {
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

			marker.Store(runMarker{Phase: "payload_sweep", StageIndex: stageIndex, WorkMode: string(mode), TargetConns: maxConnections, TargetRPS: requestsPerSecond, PayloadBytes: sweepPayloadBytes})
			trafficStartedAt := time.Now().UTC()
			trafficFinishedAt := trafficStartedAt.Add(time.Duration(payloadSweepSeconds) * time.Second)
			sendResult := sendRequests(runCtx, trafficStartedAt, trafficFinishedAt, requestsPerSecond, stageIndex, sweepPayload, false, mode, &requestID, &scheduled, &dispatched, &errorsCount, &dispatchMisses, &activeMu, &activeConns, &marker, errorLog)
			waitForInFlight(runCtx, &activeMu, &activeConns)
			trafficEndedAt := time.Now().UTC()
			finishedAt := time.Now().UTC()

			allLatenciesMu.Lock()
			stageLatencies := append([]float64(nil), allLatencies[stageLatencyStart:]...)
			allLatenciesMu.Unlock()
			stages = append(stages, stageSummary{
				Index:                   stageIndex,
				Phase:                   "payload_sweep",
				WorkMode:                string(mode),
				TargetConnections:       maxConnections,
				TargetRequestsPerSecond: requestsPerSecond,
				TargetRequests:          targetRequestCount(requestsPerSecond, payloadSweepSeconds, false),
				PayloadBytes:            sweepPayloadBytes,
				StartedAt:               stageStarted.Format(time.RFC3339),
				TrafficStartedAt:        trafficStartedAt.Format(time.RFC3339),
				DispatchFinishedAt:      sendResult.FinishedAt.Format(time.RFC3339),
				TrafficFinishedAt:       trafficEndedAt.Format(time.RFC3339),
				FinishedAt:              finishedAt.Format(time.RFC3339),
				RampSeconds:             0,
				RampReachedTarget:       true,
				TrafficRan:              true,
				TrafficSeconds:          payloadSweepSeconds,
				StabilizeSeconds:        0,
				SendSeconds:             ceilSeconds(sendResult.FinishedAt.Sub(sendResult.StartedAt)),
				DrainSeconds:            ceilSeconds(trafficEndedAt.Sub(sendResult.FinishedAt)),
				ElapsedSeconds:          ceilSeconds(finishedAt.Sub(stageStarted)),
				ActiveConnections:       active.Load(),
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
	}

	if runCtx.Err() == nil {
		marker.Store(runMarker{Phase: "cooldown", StageIndex: len(stages) - 1, TargetConns: maxConnections, TargetRPS: requestsPerSecond, PayloadBytes: payloadBytes})
		if waitPhase(runCtx, time.Duration(cooldownSeconds)*time.Second) != nil {
			cancel()
		}
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
		WorkMode:                string(mode),
		Connections:             maxConnections,
		ConnectionTargets:       connectionSchedule,
		ConnectionRetries:       connectionRetries,
		ConnectionRetryDelayMS:  connectionRetryDelay.Milliseconds(),
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
		PeakActiveConnections:   peak.Load(),
		Complete:                true,
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
	activeNow := c.active.Add(1)
	updatePeak(c.peak, activeNow)
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
		TargetConns:    marker.TargetConns,
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
		TargetConns:    marker.TargetConns,
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

func targetRequestCount(requestsPerSecond int, seconds int, rampRPS bool) uint64 {
	if requestsPerSecond <= 0 || seconds <= 0 {
		return 0
	}
	if !rampRPS {
		return uint64(requestsPerSecond) * uint64(seconds)
	}

	total := uint64(0)
	for second := 1; second <= seconds; second++ {
		targetRPS := math.Min(float64(requestsPerSecond), float64(requestsPerSecond)*float64(second)/float64(seconds))
		total += uint64(math.Round(targetRPS))
	}
	return total
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

func openConnections(ctx context.Context, targetConnections int, targetConnectionRate int, targets []target, payload string, connectionRetries int, connectionRetryDelay time.Duration, active *atomic.Int64, peak *atomic.Int64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, inFlight *atomic.Int64, connectionAttempts *atomic.Uint64, connectionRetryAttempts *atomic.Uint64, connectionFailures *atomic.Uint64, latencyCh chan<- latencySample, registerCh chan<- *clientConn, wg *sync.WaitGroup, marker *atomic.Value, errorLog *errorLogger) connectionRampResult {
	if targetConnections <= 0 {
		return connectionRampResult{TargetReached: true}
	}

	opened := int(active.Load())
	if opened >= targetConnections {
		return connectionRampResult{TargetReached: true, Launched: opened}
	}

	var carry float64
	tickInterval := time.Second
	perTick := float64(targetConnectionRate) * tickInterval.Seconds()
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	maxAttemptDuration := 20 * time.Second
	stallTimeout := time.Duration(connectionRetries+1)*maxAttemptDuration + time.Duration(connectionRetries)*connectionRetryDelay + 30*time.Second
	var launchedAllAt time.Time
	terminalFailuresAtStart := connectionFailures.Load()
	launched := opened

	launchBatch := func() {
		carry += perTick
		batch := int(math.Floor(carry))
		carry -= float64(batch)
		if batch < 1 {
			batch = 1
		}

		for i := 0; i < batch && launched < targetConnections; i++ {
			client := &clientConn{
				id:            launched,
				target:        targets[launched%len(targets)],
				payload:       payload,
				sendCh:        make(chan requestDispatch, 1),
				active:        active,
				peak:          peak,
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

			launched++
			wg.Add(1)
			go func() {
				defer wg.Done()
				client.run(ctx)
			}()
		}
	}

	for int(active.Load()) < targetConnections {
		terminalFailures := int(connectionFailures.Load() - terminalFailuresAtStart)
		if launched >= targetConnections && terminalFailures > 0 && int(active.Load())+terminalFailures >= targetConnections {
			activeNow := active.Load()
			reason := fmt.Sprintf("connection ramp failed after %d/%d active connections with %d failed connection slots after retries", activeNow, targetConnections, terminalFailures)
			logDispatchError(errorLog, marker, "ramp", 0, errors.New(reason))
			return connectionRampResult{TargetReached: false, FailureReason: reason, Launched: launched}
		}

		select {
		case <-ctx.Done():
			return connectionRampResult{TargetReached: false, FailureReason: ctx.Err().Error(), Launched: launched}
		case <-ticker.C:
			if launched < targetConnections {
				launchBatch()
				if launched >= targetConnections {
					launchedAllAt = time.Now()
				}
			} else if launchedAllAt.IsZero() {
				launchedAllAt = time.Now()
			} else if time.Since(launchedAllAt) >= stallTimeout {
				activeNow := active.Load()
				reason := fmt.Sprintf("connection ramp stalled at %d/%d active connections after launching %d connection slots", activeNow, targetConnections, launched)
				logDispatchError(errorLog, marker, "ramp", 0, errors.New(reason))
				return connectionRampResult{TargetReached: false, FailureReason: reason, Launched: launched}
			}
		}
	}

	return connectionRampResult{TargetReached: true, Launched: launched}
}

func sendRequests(ctx context.Context, start time.Time, end time.Time, requestsPerSecond int, stageIndex int, payload string, rampRPS bool, mode workMode, requestID *atomic.Uint64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, activeMu *sync.Mutex, activeConns *[]*clientConn, marker *atomic.Value, errorLog *errorLogger) sendResult {
	result := sendResult{StartedAt: start, FinishedAt: time.Now().UTC()}
	if requestsPerSecond <= 0 {
		waitUntil(ctx, end)
		result.FinishedAt = time.Now().UTC()
		return result
	}

	tickInterval := 100 * time.Millisecond
	totalTicks := int(end.Sub(start) / tickInterval)
	totalSeconds := end.Sub(start).Seconds()
	rpsStep := float64(requestsPerSecond) / totalSeconds
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

		elapsedSeconds := math.Ceil(tickTime.Sub(start).Seconds())
		targetRPS := float64(requestsPerSecond)
		if rampRPS {
			targetRPS = math.Min(float64(requestsPerSecond), rpsStep*elapsedSeconds)
		}
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

func sampleMetrics(ctx context.Context, startedAt time.Time, marker *atomic.Value, file *os.File, active *atomic.Int64, inFlight *atomic.Int64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, connectionAttempts *atomic.Uint64, connectionRetryAttempts *atomic.Uint64, connectionFailures *atomic.Uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
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
	var lastConnectionAttempts uint64
	var lastConnectionRetries uint64
	var lastConnectionFailures uint64
	drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, active, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, connectionAttempts, connectionRetryAttempts, connectionFailures, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, &lastConnectionAttempts, &lastConnectionRetries, &lastConnectionFailures, latencyCh, recordLatencies)

	for {
		select {
		case <-ctx.Done():
			drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, active, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, connectionAttempts, connectionRetryAttempts, connectionFailures, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, &lastConnectionAttempts, &lastConnectionRetries, &lastConnectionFailures, latencyCh, recordLatencies)
			return
		case <-ticker.C:
			drainAndWriteSample(time.Now().UTC(), startedAt, currentMarker(marker), encoder, active, inFlight, scheduled, dispatched, sent, received, errorsCount, dispatchMisses, connectionAttempts, connectionRetryAttempts, connectionFailures, &lastSampleAt, &lastScheduled, &lastDispatched, &lastSent, &lastReceived, &lastErrors, &lastDispatchMisses, &lastConnectionAttempts, &lastConnectionRetries, &lastConnectionFailures, latencyCh, recordLatencies)
		}
	}
}

func drainAndWriteSample(now time.Time, startedAt time.Time, marker runMarker, encoder *json.Encoder, active *atomic.Int64, inFlight *atomic.Int64, scheduled *atomic.Uint64, dispatched *atomic.Uint64, sent *atomic.Uint64, received *atomic.Uint64, errorsCount *atomic.Uint64, dispatchMisses *atomic.Uint64, connectionAttempts *atomic.Uint64, connectionRetryAttempts *atomic.Uint64, connectionFailures *atomic.Uint64, lastSampleAt *time.Time, lastScheduled *uint64, lastDispatched *uint64, lastSent *uint64, lastReceived *uint64, lastErrors *uint64, lastDispatchMisses *uint64, lastConnectionAttempts *uint64, lastConnectionRetries *uint64, lastConnectionFailures *uint64, latencyCh <-chan latencySample, recordLatencies func([]latencySample)) {
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
			currentConnectionAttempts := connectionAttempts.Load()
			currentConnectionRetries := connectionRetryAttempts.Load()
			currentConnectionFailures := connectionFailures.Load()
			deltaSeconds := math.Max(now.Sub(*lastSampleAt).Seconds(), 0.001)

			sample := metricSample{
				Timestamp:                   now.Format(time.RFC3339Nano),
				ElapsedSeconds:              int64(now.Sub(startedAt).Seconds()),
				ElapsedMS:                   now.Sub(startedAt).Milliseconds(),
				WorkMode:                    marker.WorkMode,
				Phase:                       marker.Phase,
				StageIndex:                  marker.StageIndex,
				TargetConns:                 marker.TargetConns,
				TargetRPS:                   marker.TargetRPS,
				PayloadBytes:                marker.PayloadBytes,
				ActiveConns:                 active.Load(),
				InFlight:                    inFlight.Load(),
				Scheduled:                   currentScheduled,
				Dispatched:                  currentDispatched,
				Sent:                        currentSent,
				Received:                    currentReceived,
				Errors:                      currentErrors,
				DispatchMisses:              currentDispatchMisses,
				ConnectionAttempts:          currentConnectionAttempts,
				ConnectionRetries:           currentConnectionRetries,
				ConnectionFailures:          currentConnectionFailures,
				ScheduledPerSecond:          ratePerSecond(currentScheduled-*lastScheduled, deltaSeconds),
				DispatchedPerSecond:         ratePerSecond(currentDispatched-*lastDispatched, deltaSeconds),
				SentPerSecond:               ratePerSecond(currentSent-*lastSent, deltaSeconds),
				ReceivedPerSecond:           ratePerSecond(currentReceived-*lastReceived, deltaSeconds),
				ErrorsPerSecond:             ratePerSecond(currentErrors-*lastErrors, deltaSeconds),
				DispatchMissesPerSecond:     ratePerSecond(currentDispatchMisses-*lastDispatchMisses, deltaSeconds),
				ConnectionAttemptsPerSecond: ratePerSecond(currentConnectionAttempts-*lastConnectionAttempts, deltaSeconds),
				ConnectionRetriesPerSecond:  ratePerSecond(currentConnectionRetries-*lastConnectionRetries, deltaSeconds),
				ConnectionFailuresPerSecond: ratePerSecond(currentConnectionFailures-*lastConnectionFailures, deltaSeconds),
				P50LatencyMS:                percentile(latencyValues(latencies), 50),
				P90LatencyMS:                percentile(latencyValues(latencies), 90),
				P99LatencyMS:                percentile(latencyValues(latencies), 99),
				MaxLatencyMS:                percentile(latencyValues(latencies), 100),
			}

			_ = encoder.Encode(sample)
			*lastSampleAt = now
			*lastScheduled = currentScheduled
			*lastDispatched = currentDispatched
			*lastSent = currentSent
			*lastReceived = currentReceived
			*lastErrors = currentErrors
			*lastDispatchMisses = currentDispatchMisses
			*lastConnectionAttempts = currentConnectionAttempts
			*lastConnectionRetries = currentConnectionRetries
			*lastConnectionFailures = currentConnectionFailures
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
