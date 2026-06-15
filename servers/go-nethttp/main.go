package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const maxSafeInteger = 9007199254740991

var startedAt = time.Now().UTC()

type counters struct {
	activeRequests     atomic.Int64
	requestsStarted    atomic.Int64
	responsesCompleted atomic.Int64
	responses2xx       atomic.Int64
	responses4xx       atomic.Int64
	responses5xx       atomic.Int64
	requestErrors      atomic.Int64
}

type serverState struct {
	counters *counters
	events   *jsonlWriter
}

type jsonlWriter struct {
	mu   sync.Mutex
	file *os.File
}

type requestBody struct {
	ID      json.Number `json:"id"`
	Payload *string     `json:"payload"`
}

func main() {
	ports, err := parsePorts(firstNonEmpty(os.Getenv("PORTS"), os.Getenv("PORT"), "8080"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "go-nethttp: %v\n", err)
		os.Exit(1)
	}

	host := firstNonEmpty(os.Getenv("HOST"), "127.0.0.1")
	c := &counters{}
	activity := openJSONL(os.Getenv("ACTIVITY_METRICS_PATH"))
	events := openJSONL(os.Getenv("SERVER_EVENTS_PATH"))
	runtimeMetrics := openJSONL(os.Getenv("RUNTIME_METRICS_PATH"))
	state := &serverState{counters: c, events: events}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var servers []*http.Server
	for _, port := range ports {
		mux := http.NewServeMux()
		mux.HandleFunc("/health", state.handleHealth)
		mux.HandleFunc("/runtime", state.handleRuntime)
		mux.HandleFunc("/json", state.handleJSON)
		mux.HandleFunc("/", state.handleNotFound)

		server := &http.Server{
			Addr:              fmt.Sprintf("%s:%d", host, port),
			Handler:           mux,
			ReadHeaderTimeout: 10 * time.Second,
		}
		servers = append(servers, server)
		go func(s *http.Server, p int) {
			fmt.Printf("go net/http JSON server listening on http://%s:%d\n", host, p)
			if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				fmt.Fprintf(os.Stderr, "go-nethttp: listen on port %d: %v\n", p, err)
				os.Exit(1)
			}
		}(server, port)
	}

	if activity != nil {
		writeActivity(activity, c)
		go sampleEvery(ctx, activity, func(w *jsonlWriter) { writeActivity(w, c) })
	}
	if runtimeMetrics != nil {
		writeRuntime(runtimeMetrics)
		go sampleEvery(ctx, runtimeMetrics, func(w *jsonlWriter) { writeRuntime(w) })
	}

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	for _, server := range servers {
		_ = server.Shutdown(shutdownCtx)
	}
	closeJSONL(activity)
	closeJSONL(events)
	closeJSONL(runtimeMetrics)
}

func (s *serverState) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                         true,
		"active_connections":         nil,
		"accepted_connections_total": nil,
		"closed_connections_total":   nil,
		"active_requests":            s.counters.activeRequests.Load(),
		"requests_started_total":     s.counters.requestsStarted.Load(),
		"responses_completed_total":  s.counters.responsesCompleted.Load(),
		"total_errors":               s.counters.requestErrors.Load(),
	})
}

func (s *serverState) handleRuntime(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, runtimeSample())
}

func (s *serverState) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
}

func (s *serverState) handleJSON(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}

	s.counters.activeRequests.Add(1)
	s.counters.requestsStarted.Add(1)
	defer s.counters.activeRequests.Add(-1)

	var request requestBody
	decoder := json.NewDecoder(r.Body)
	decoder.UseNumber()
	if err := decoder.Decode(&request); err != nil {
		s.failMeasured(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		s.failMeasured(w, http.StatusBadRequest, "invalid_json")
		return
	}
	id, err := parseID(request.ID)
	if err != nil || request.Payload == nil {
		s.failMeasured(w, http.StatusBadRequest, "invalid_request")
		return
	}

	recordResponse(s.counters, http.StatusOK)
	writeJSON(w, http.StatusOK, map[string]any{
		"id":       id,
		"len":      len([]byte(*request.Payload)),
		"checksum": checksum([]byte(*request.Payload)),
	})
}

func (s *serverState) failMeasured(w http.ResponseWriter, status int, reason string) {
	s.counters.requestErrors.Add(1)
	recordResponse(s.counters, status)
	writeEvent(s.events, "request_error", map[string]any{"reason": reason, "status_code": status})
	writeJSON(w, status, map[string]string{"error": reason})
}

func parseID(value json.Number) (int64, error) {
	if value == "" || strings.ContainsAny(value.String(), ".eE") {
		return 0, errors.New("id is not an integer")
	}
	id, err := strconv.ParseInt(value.String(), 10, 64)
	if err != nil || id < 0 || id > maxSafeInteger {
		return 0, errors.New("id out of range")
	}
	return id, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		body = []byte(`{"error":"internal_error"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func recordResponse(c *counters, status int) {
	c.responsesCompleted.Add(1)
	if status >= 200 && status < 300 {
		c.responses2xx.Add(1)
	} else if status >= 400 && status < 500 {
		c.responses4xx.Add(1)
	} else if status >= 500 {
		c.responses5xx.Add(1)
	}
}

func checksum(payload []byte) uint32 {
	value := uint32(2166136261)
	for _, b := range payload {
		value ^= uint32(b)
		value *= 16777619
	}
	return value
}

func activitySample(c *counters) map[string]any {
	return map[string]any{
		"ts":                         time.Now().UTC().Format(time.RFC3339),
		"elapsed_seconds":            elapsedSeconds(),
		"active_connections":         nil,
		"accepted_connections_total": nil,
		"closed_connections_total":   nil,
		"active_requests":            c.activeRequests.Load(),
		"requests_started_total":     c.requestsStarted.Load(),
		"responses_completed_total":  c.responsesCompleted.Load(),
		"responses_2xx_total":        c.responses2xx.Load(),
		"responses_4xx_total":        c.responses4xx.Load(),
		"responses_5xx_total":        c.responses5xx.Load(),
		"request_errors_total":       c.requestErrors.Load(),
	}
}

func runtimeSample() map[string]any {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return map[string]any{
		"ts":                time.Now().UTC().Format(time.RFC3339),
		"elapsed_seconds":   elapsedSeconds(),
		"runtime":           "go-nethttp",
		"heap_total_bytes":  stats.HeapSys,
		"heap_used_bytes":   stats.HeapAlloc,
		"rss_bytes":         stats.Sys,
		"goroutines":        runtime.NumGoroutine(),
		"gc_cycles_total":   stats.NumGC,
		"gc_pause_total_ns": stats.PauseTotalNs,
	}
}

func writeActivity(w *jsonlWriter, c *counters) {
	writeJSONL(w, activitySample(c))
}

func writeRuntime(w *jsonlWriter) {
	writeJSONL(w, runtimeSample())
}

func writeEvent(w *jsonlWriter, event string, fields map[string]any) {
	if w == nil {
		return
	}
	entry := map[string]any{
		"ts":              time.Now().UTC().Format(time.RFC3339),
		"elapsed_seconds": elapsedSeconds(),
		"event":           event,
	}
	for key, value := range fields {
		entry[key] = value
	}
	writeJSONL(w, entry)
}

func sampleEvery(ctx context.Context, w *jsonlWriter, fn func(*jsonlWriter)) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fn(w)
		}
	}
}

func openJSONL(path string) *jsonlWriter {
	if path == "" {
		return nil
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "go-nethttp: open metrics file %s: %v\n", path, err)
		os.Exit(1)
	}
	return &jsonlWriter{file: file}
}

func writeJSONL(w *jsonlWriter, value any) {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_ = json.NewEncoder(w.file).Encode(value)
}

func closeJSONL(w *jsonlWriter) {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_ = w.file.Close()
}

func elapsedSeconds() int64 {
	return int64(time.Since(startedAt).Seconds())
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func parsePorts(value string) ([]int, error) {
	seen := map[int]bool{}
	var ports []int
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		port, err := strconv.Atoi(item)
		if err != nil || port <= 0 || port >= 65536 {
			return nil, fmt.Errorf("invalid port %q", item)
		}
		if !seen[port] {
			seen[port] = true
			ports = append(ports, port)
		}
	}
	if len(ports) == 0 {
		return nil, errors.New("PORTS must contain at least one TCP port")
	}
	return ports, nil
}
