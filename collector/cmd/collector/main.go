package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const clockTicksPerSecond = 100.0

type sample struct {
	Timestamp            string  `json:"ts"`
	ElapsedSeconds       int64   `json:"elapsed_seconds"`
	PID                  int     `json:"pid"`
	CPUPercent           float64 `json:"cpu_percent"`
	RSSBytes             uint64  `json:"rss_bytes"`
	RSSMB                float64 `json:"rss_mb"`
	Threads              *int    `json:"threads,omitempty"`
	OpenFDs              *int    `json:"open_fds,omitempty"`
	TCPSockets           *int    `json:"tcp_sockets,omitempty"`
	TCPEstablished       *int    `json:"tcp_established,omitempty"`
	TCPListen            *int    `json:"tcp_listen,omitempty"`
	TCPCloseWait         *int    `json:"tcp_close_wait,omitempty"`
	TCPListenOverflows   *uint64 `json:"tcp_listen_overflows,omitempty"`
	TCPListenDrops       *uint64 `json:"tcp_listen_drops,omitempty"`
	TCPBacklogDrop       *uint64 `json:"tcp_backlog_drop,omitempty"`
	TCPReqQFullDoCookies *uint64 `json:"tcp_req_q_full_do_cookies,omitempty"`
	TCPReqQFullDrop      *uint64 `json:"tcp_req_q_full_drop,omitempty"`
	TCPSyncookiesSent    *uint64 `json:"tcp_syncookies_sent,omitempty"`
	TCPSyncookiesRecv    *uint64 `json:"tcp_syncookies_recv,omitempty"`
	TCPSyncookiesFailed  *uint64 `json:"tcp_syncookies_failed,omitempty"`
	TCPEmbryonicRsts     *uint64 `json:"tcp_embryonic_rsts,omitempty"`
	Error                string  `json:"error,omitempty"`
}

type linuxProcessSample struct {
	processTicks   uint64
	systemTicks    uint64
	rssBytes       uint64
	threads        *int
	openFDs        *int
	tcpSockets     *int
	tcpEstablished *int
	tcpListen      *int
	tcpCloseWait   *int
	tcpExt         tcpExtCounters
}

type tcpExtCounters struct {
	ListenOverflows   *uint64
	ListenDrops       *uint64
	BacklogDrop       *uint64
	ReqQFullDoCookies *uint64
	ReqQFullDrop      *uint64
	SyncookiesSent    *uint64
	SyncookiesRecv    *uint64
	SyncookiesFailed  *uint64
	EmbryonicRsts     *uint64
}

type linuxCollector struct {
	pid       int
	last      *linuxProcessSample
	cpuCount  int
	pageBytes uint64
}

func main() {
	var pid int
	var outputPath string
	var interval time.Duration

	flag.IntVar(&pid, "pid", 0, "process id to collect")
	flag.StringVar(&outputPath, "output", "server_metrics.jsonl", "output JSONL file")
	flag.DurationVar(&interval, "interval", time.Second, "sample interval")
	flag.Parse()

	if pid <= 0 {
		fmt.Fprintln(os.Stderr, "collector: --pid is required")
		os.Exit(1)
	}
	if interval <= 0 {
		fmt.Fprintln(os.Stderr, "collector: --interval must be positive")
		os.Exit(1)
	}

	if dir := filepath.Dir(outputPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "collector: create output directory: %v\n", err)
			os.Exit(1)
		}
	}

	file, err := os.Create(outputPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "collector: create output: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	encoder := json.NewEncoder(file)
	startedAt := time.Now().UTC()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	linux := newLinuxCollector(pid)

	for {
		writeSample(encoder, pid, startedAt, linux)

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func writeSample(encoder *json.Encoder, pid int, startedAt time.Time, linux *linuxCollector) {
	now := time.Now().UTC()
	cpu, rssBytes, threads, openFDs, tcpSockets, tcpEstablished, tcpListen, tcpCloseWait, tcpExt, err := readProcess(pid, linux)
	entry := sample{
		Timestamp:            now.Format(time.RFC3339),
		ElapsedSeconds:       int64(now.Sub(startedAt).Seconds()),
		PID:                  pid,
		CPUPercent:           cpu,
		RSSBytes:             rssBytes,
		RSSMB:                float64(rssBytes) / 1024 / 1024,
		Threads:              threads,
		OpenFDs:              openFDs,
		TCPSockets:           tcpSockets,
		TCPEstablished:       tcpEstablished,
		TCPListen:            tcpListen,
		TCPCloseWait:         tcpCloseWait,
		TCPListenOverflows:   tcpExt.ListenOverflows,
		TCPListenDrops:       tcpExt.ListenDrops,
		TCPBacklogDrop:       tcpExt.BacklogDrop,
		TCPReqQFullDoCookies: tcpExt.ReqQFullDoCookies,
		TCPReqQFullDrop:      tcpExt.ReqQFullDrop,
		TCPSyncookiesSent:    tcpExt.SyncookiesSent,
		TCPSyncookiesRecv:    tcpExt.SyncookiesRecv,
		TCPSyncookiesFailed:  tcpExt.SyncookiesFailed,
		TCPEmbryonicRsts:     tcpExt.EmbryonicRsts,
	}
	if err != nil {
		entry.Error = err.Error()
	}

	_ = encoder.Encode(entry)
}

func readProcess(pid int, linux *linuxCollector) (float64, uint64, *int, *int, *int, *int, *int, *int, tcpExtCounters, error) {
	if runtime.GOOS == "linux" {
		cpu, rssBytes, threads, openFDs, tcpSockets, tcpEstablished, tcpListen, tcpCloseWait, tcpExt, err := linux.read()
		if err == nil {
			return cpu, rssBytes, threads, openFDs, tcpSockets, tcpEstablished, tcpListen, tcpCloseWait, tcpExt, nil
		}
	}

	cpu, rssKB, err := readPS(pid)
	return cpu, rssKB * 1024, readThreads(pid), readOpenFDs(pid), nil, nil, nil, nil, tcpExtCounters{}, err
}

func newLinuxCollector(pid int) *linuxCollector {
	return &linuxCollector{
		pid:       pid,
		cpuCount:  max(runtime.NumCPU(), 1),
		pageBytes: uint64(os.Getpagesize()),
	}
}

func (collector *linuxCollector) read() (float64, uint64, *int, *int, *int, *int, *int, *int, tcpExtCounters, error) {
	current, err := collector.readRaw()
	if err != nil {
		return 0, 0, nil, nil, nil, nil, nil, nil, tcpExtCounters{}, err
	}

	cpu := 0.0
	if collector.last != nil {
		processDelta := current.processTicks - collector.last.processTicks
		systemDelta := current.systemTicks - collector.last.systemTicks
		if systemDelta > 0 {
			cpu = (float64(processDelta) / float64(systemDelta)) * float64(collector.cpuCount) * 100
		}
	}
	collector.last = current

	return cpu, current.rssBytes, current.threads, current.openFDs, current.tcpSockets, current.tcpEstablished, current.tcpListen, current.tcpCloseWait, current.tcpExt, nil
}

func (collector *linuxCollector) readRaw() (*linuxProcessSample, error) {
	processTicks, rssBytes, err := readLinuxStat(collector.pid, collector.pageBytes)
	if err != nil {
		return nil, err
	}
	systemTicks, err := readLinuxSystemTicks()
	if err != nil {
		return nil, err
	}

	tcpSockets, tcpEstablished, tcpListen, tcpCloseWait := readTCPStateCounts(collector.pid)
	tcpExt := readTCPExtCounters()

	return &linuxProcessSample{
		processTicks:   processTicks,
		systemTicks:    systemTicks,
		rssBytes:       rssBytes,
		threads:        readThreads(collector.pid),
		openFDs:        readOpenFDs(collector.pid),
		tcpSockets:     tcpSockets,
		tcpEstablished: tcpEstablished,
		tcpListen:      tcpListen,
		tcpCloseWait:   tcpCloseWait,
		tcpExt:         tcpExt,
	}, nil
}

func readLinuxStat(pid int, pageBytes uint64) (uint64, uint64, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, 0, err
	}

	line := strings.TrimSpace(string(data))
	closeParen := strings.LastIndex(line, ")")
	if closeParen < 0 || closeParen+2 >= len(line) {
		return 0, 0, fmt.Errorf("unexpected /proc stat format")
	}

	fields := strings.Fields(line[closeParen+2:])
	if len(fields) < 22 {
		return 0, 0, fmt.Errorf("unexpected /proc stat field count")
	}

	utime, err := strconv.ParseUint(fields[11], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	stime, err := strconv.ParseUint(fields[12], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	rssPages, err := strconv.ParseInt(fields[21], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	if rssPages < 0 {
		rssPages = 0
	}

	return utime + stime, uint64(rssPages) * pageBytes, nil
}

func readLinuxSystemTicks() (uint64, error) {
	file, err := os.Open("/proc/stat")
	if err != nil {
		return 0, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	if !scanner.Scan() {
		return 0, scanner.Err()
	}

	fields := strings.Fields(scanner.Text())
	if len(fields) < 2 || fields[0] != "cpu" {
		return 0, fmt.Errorf("unexpected /proc/stat format")
	}

	var total uint64
	for _, field := range fields[1:] {
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return 0, err
		}
		total += value
	}
	return total, nil
}

func readPS(pid int) (float64, uint64, error) {
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "pcpu=", "-o", "rss=")
	output, err := cmd.Output()
	if err != nil {
		return 0, 0, err
	}

	fields := strings.Fields(string(output))
	if len(fields) < 2 {
		return 0, 0, fmt.Errorf("unexpected ps output: %q", strings.TrimSpace(string(output)))
	}

	cpu, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, 0, err
	}

	rssKB, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0, 0, err
	}

	return cpu, rssKB, nil
}

func readThreads(pid int) *int {
	if runtime.GOOS != "linux" {
		return nil
	}

	file, err := os.Open(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return nil
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "Threads:") {
			fields := strings.Fields(line)
			if len(fields) == 2 {
				value, err := strconv.Atoi(fields[1])
				if err == nil {
					return &value
				}
			}
		}
	}

	return nil
}

func readOpenFDs(pid int) *int {
	if runtime.GOOS != "linux" {
		return nil
	}

	entries, err := os.ReadDir(fmt.Sprintf("/proc/%d/fd", pid))
	if err != nil {
		return nil
	}

	value := len(entries)
	return &value
}

func readTCPStateCounts(pid int) (*int, *int, *int, *int) {
	if runtime.GOOS != "linux" {
		return nil, nil, nil, nil
	}

	inodes := socketInodes(pid)
	if len(inodes) == 0 {
		zero := 0
		return &zero, &zero, &zero, &zero
	}

	total, established, listen, closeWait := 0, 0, 0, 0
	for _, filePath := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		file, err := os.Open(filePath)
		if err != nil {
			continue
		}
		scanner := bufio.NewScanner(file)
		if scanner.Scan() {
			// header
		}
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) < 10 {
				continue
			}
			if !inodes[fields[9]] {
				continue
			}
			total++
			switch fields[3] {
			case "01":
				established++
			case "0A":
				listen++
			case "08":
				closeWait++
			}
		}
		_ = file.Close()
	}

	return &total, &established, &listen, &closeWait
}

func readTCPExtCounters() tcpExtCounters {
	if runtime.GOOS != "linux" {
		return tcpExtCounters{}
	}

	file, err := os.Open("/proc/net/netstat")
	if err != nil {
		return tcpExtCounters{}
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var headers []string
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 || fields[0] != "TcpExt:" {
			continue
		}
		if headers == nil {
			headers = fields[1:]
			continue
		}

		values := fields[1:]
		if len(values) != len(headers) {
			headers = nil
			continue
		}

		byName := make(map[string]uint64, len(headers))
		for index, name := range headers {
			value, err := strconv.ParseUint(values[index], 10, 64)
			if err != nil {
				continue
			}
			byName[name] = value
		}
		return tcpExtCounters{
			ListenOverflows:   optionalUint64(byName, "ListenOverflows"),
			ListenDrops:       optionalUint64(byName, "ListenDrops"),
			BacklogDrop:       optionalUint64(byName, "TCPBacklogDrop"),
			ReqQFullDoCookies: optionalUint64(byName, "TCPReqQFullDoCookies"),
			ReqQFullDrop:      optionalUint64(byName, "TCPReqQFullDrop"),
			SyncookiesSent:    optionalUint64(byName, "SyncookiesSent"),
			SyncookiesRecv:    optionalUint64(byName, "SyncookiesRecv"),
			SyncookiesFailed:  optionalUint64(byName, "SyncookiesFailed"),
			EmbryonicRsts:     optionalUint64(byName, "EmbryonicRsts"),
		}
	}

	return tcpExtCounters{}
}

func optionalUint64(values map[string]uint64, key string) *uint64 {
	value, ok := values[key]
	if !ok {
		return nil
	}
	return &value
}

func socketInodes(pid int) map[string]bool {
	entries, err := os.ReadDir(fmt.Sprintf("/proc/%d/fd", pid))
	if err != nil {
		return nil
	}

	inodes := make(map[string]bool)
	for _, entry := range entries {
		target, err := os.Readlink(fmt.Sprintf("/proc/%d/fd/%s", pid, entry.Name()))
		if err != nil || !strings.HasPrefix(target, "socket:[") || !strings.HasSuffix(target, "]") {
			continue
		}
		inode := strings.TrimSuffix(strings.TrimPrefix(target, "socket:["), "]")
		if inode != "" {
			inodes[inode] = true
		}
	}
	return inodes
}
