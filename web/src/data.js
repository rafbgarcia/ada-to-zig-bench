export const metricGroups = [
  {
    id: 'connections',
    title: 'Active Connections',
    description: 'Active connections reported by the measured server process.',
    unit: '',
    series: [
      { key: 'serverConnections', label: 'Active connections', color: '#0f766e' },
    ],
  },
  {
    id: 'work',
    title: 'Successful Responses',
    description: 'Successful /json responses per second from the measured server process.',
    unit: '/s',
    series: [
      { key: 'responses2xxPerSecond', label: 'Responses', color: '#0f766e', unit: '/s' },
    ],
  },
  {
    id: 'inflight',
    title: 'In-Flight Requests',
    description: 'Current requests active in the measured server process.',
    unit: '',
    series: [
      { key: 'activeRequests', label: 'In flight', color: '#7c3aed' },
    ],
  },
  {
    id: 'cpu',
    title: 'CPU Percentage',
    description: 'Server process CPU percentage sampled externally by the collector.',
    unit: '%',
    series: [
      { key: 'cpuPercent', label: 'CPU', color: '#b42318', unit: '%' },
    ],
  },
  {
    id: 'memory',
    title: 'RSS Memory',
    description: 'Server process resident memory sampled externally by the collector.',
    unit: 'MB',
    series: [
      { key: 'rssMb', label: 'RSS', color: '#0891b2', unit: 'MB' },
    ],
  },
  {
    id: 'fds',
    title: 'Open File Descriptors',
    description: 'Open file descriptors for the measured server process.',
    unit: '',
    series: [
      { key: 'openFds', label: 'Open FDs', color: '#666666' },
    ],
  },
  {
    id: 'threads',
    title: 'Threads',
    description: 'Thread count for the measured server process.',
    unit: '',
    series: [
      { key: 'threads', label: 'Threads', color: '#7c3aed' },
    ],
  },
  // {
  //   id: 'efficiency',
  //   title: 'Resource Efficiency',
  //   description: 'Derived resource cost normalized by live connection and request volume.',
  //   unit: '',
  //   series: [
  //     { key: 'rssMbPer10kConnections', label: 'RSS / 10k conns', color: '#0891b2', unit: 'MB' },
  //     { key: 'fdsPerConnection', label: 'FDs / conn', color: '#334155' },
  //     { key: 'cpuPercentPer10kRps', label: 'CPU% / 10k RPS', color: '#b42318', unit: '%' },
  //   ],
  // },
  {
    id: 'runtime',
    title: 'Runtime Memory',
    description: 'Runtime heap counters where the implementation exposes them.',
    unit: 'MB',
    series: [
      { key: 'heapUsedMb', label: 'Heap used', color: '#8b5cf6', unit: 'MB' },
      { key: 'heapTotalMb', label: 'Heap total', color: '#14b8a6', unit: 'MB' },
    ],
  },
  {
    id: 'errors',
    title: 'Server Errors And TCP Pressure',
    description: 'Invalid request responses and kernel TCP queue pressure.',
    unit: '/s',
    series: [
      { key: 'serverErrorsPerSecond', label: 'Invalid requests', color: '#dc2626', unit: '/s' },
      { key: 'tcpListenDropsDelta', label: 'Listen drops', color: '#b45309', unit: '/s' },
      { key: 'tcpListenOverflowsDelta', label: 'Listen overflows', color: '#9f1239', unit: '/s' },
      { key: 'tcpBacklogDropDelta', label: 'Backlog drops', color: '#a16207', unit: '/s' },
      { key: 'tcpReqQFullDropDelta', label: 'Full queue drops', color: '#881337', unit: '/s' },
    ],
  },
];

export const phaseColors = {
  baseline: '#64748b',
  ramp: '#2563eb',
  settle: '#16a34a',
  traffic: '#f97316',
  stabilize: '#7c3aed',
  ramp_failed: '#dc2626',
  payload_sweep: '#0d9488',
  cooldown: '#94a3b8',
  unknown: '#cbd5e1',
};

export const phaseLabels = {
  baseline: 'Baseline',
  ramp: 'Ramp',
  settle: 'Settle',
  traffic: 'Traffic',
  stabilize: 'Stabilize',
  ramp_failed: 'Ramp failed',
  payload_sweep: 'Payload sweep',
  cooldown: 'Cooldown',
  unknown: 'Unknown',
};

export async function fetchRuns() {
  return fetchJSON('runs.json');
}

export async function loadRun(runID) {
  const [metadata, summary, serverRaw, activityRaw, loadgenRaw, runtimeRaw, serverEventsRaw, loadgenErrorsRaw] = await Promise.all([
    fetchJSON(runFileURL(runID, 'metadata.json')),
    fetchJSON(runFileURL(runID, 'summary.json')).catch(() => null),
    fetchText(runFileURL(runID, 'server_metrics.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'activity_metrics.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'loadgen_metrics.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'runtime_metrics.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'server_events.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'loadgen_errors.jsonl')).catch(() => ''),
  ]);

  const serverMetrics = parseJSONL(serverRaw);
  const serverMetricsWithRates = withDerivedServerRates(serverMetrics);
  const activityMetrics = withDerivedActivityRates(parseJSONL(activityRaw));
  const loadgenMetrics = parseJSONL(loadgenRaw);
  const runtimeMetrics = parseJSONL(runtimeRaw).map((sample) => ({
    ...sample,
    heap_used_mb: bytesToMB(sample.heap_used_bytes ?? sample.used_heap_size_bytes ?? 0),
    heap_total_mb: bytesToMB(sample.heap_total_bytes ?? sample.total_heap_size_bytes ?? 0),
  }));
  const serverEvents = parseJSONL(serverEventsRaw);
  const loadgenErrors = parseJSONL(loadgenErrorsRaw);

  const timelineStart = findTimelineStart(metadata, serverMetricsWithRates, activityMetrics, loadgenMetrics, runtimeMetrics, serverEvents, loadgenErrors);
  for (const group of [serverMetricsWithRates, activityMetrics, loadgenMetrics, runtimeMetrics, serverEvents, loadgenErrors]) {
    annotateTimelineSeconds(group, timelineStart);
  }

  const maxElapsed = Math.max(
    0,
    ...serverMetricsWithRates.map((sample) => sample.timeline_seconds ?? 0),
    ...activityMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...loadgenMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...runtimeMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...serverEvents.map((event) => event.timeline_seconds ?? 0),
    ...loadgenErrors.map((event) => event.timeline_seconds ?? 0),
  );

  const phases = buildPhaseRanges(loadgenMetrics, maxElapsed);
  const timeline = buildTimeline({ serverMetrics: serverMetricsWithRates, activityMetrics, loadgenMetrics, runtimeMetrics, maxElapsed });

  return {
    runID,
    metadata,
    summary,
    serverMetrics: serverMetricsWithRates,
    activityMetrics,
    loadgenMetrics,
    runtimeMetrics,
    serverEvents,
    loadgenErrors,
    phases,
    timeline,
    maxElapsed: Math.round(maxElapsed),
  };
}

export function nearestSample(samples, elapsed) {
  if (!samples?.length) return null;

  let best = samples[0];
  for (const sample of samples) {
    if ((sample.timeline_seconds ?? sample.elapsed_seconds ?? 0) <= elapsed) {
      best = sample;
    } else {
      break;
    }
  }
  return best;
}

export function recentEvents(loaded, elapsed, limit = 12) {
  if (!loaded) return [];
  const events = [
    ...loaded.serverEvents.map((event) => ({ source: 'server', ...event })),
    ...loaded.loadgenErrors.map((event) => ({ source: 'loadgen', event: 'loadgen_error', ...event })),
  ];
  return events
    .filter((event) => Number(event.timeline_seconds ?? 0) <= elapsed)
    .sort((a, b) => Number(b.timeline_seconds ?? 0) - Number(a.timeline_seconds ?? 0))
    .slice(0, limit);
}

function withDerivedActivityRates(samples) {
  let previous = null;
  return samples.map((sample) => {
    const elapsed = Number(sample.elapsed_seconds ?? 0);
    const deltaSeconds = previous ? Math.max(1, elapsed - Number(previous.elapsed_seconds ?? 0)) : 1;
    const next = {
      ...sample,
      requests_started_per_second: delta(sample, previous, 'requests_started_total') / deltaSeconds,
      responses_completed_per_second: delta(sample, previous, 'responses_completed_total') / deltaSeconds,
      responses_2xx_per_second: delta(sample, previous, 'responses_2xx_total') / deltaSeconds,
      responses_4xx_per_second: delta(sample, previous, 'responses_4xx_total') / deltaSeconds,
      responses_5xx_per_second: delta(sample, previous, 'responses_5xx_total') / deltaSeconds,
      request_errors_per_second: delta(sample, previous, 'request_errors_total') / deltaSeconds,
    };
    previous = sample;
    return next;
  });
}

function withDerivedServerRates(samples) {
  let previous = null;
  return samples.map((sample) => {
    const elapsed = Number(sample.elapsed_seconds ?? 0);
    const deltaSeconds = previous ? Math.max(1, elapsed - Number(previous.elapsed_seconds ?? 0)) : 1;
    const next = {
      ...sample,
      tcp_listen_overflows_per_second: delta(sample, previous, 'tcp_listen_overflows') / deltaSeconds,
      tcp_listen_drops_per_second: delta(sample, previous, 'tcp_listen_drops') / deltaSeconds,
      tcp_backlog_drop_per_second: delta(sample, previous, 'tcp_backlog_drop') / deltaSeconds,
      tcp_req_q_full_drop_per_second: delta(sample, previous, 'tcp_req_q_full_drop') / deltaSeconds,
      tcp_syncookies_sent_per_second: delta(sample, previous, 'tcp_syncookies_sent') / deltaSeconds,
      tcp_syncookies_failed_per_second: delta(sample, previous, 'tcp_syncookies_failed') / deltaSeconds,
    };
    previous = sample;
    return next;
  });
}

function delta(sample, previous, key) {
  if (!previous) return 0;
  const current = Number(sample[key] ?? 0);
  const last = Number(previous[key] ?? 0);
  if (!Number.isFinite(current) || !Number.isFinite(last)) return 0;
  return Math.max(0, current - last);
}

function buildTimeline({ serverMetrics, activityMetrics, loadgenMetrics, runtimeMetrics, maxElapsed }) {
  const length = Math.max(1, Math.round(maxElapsed)) + 1;
  const rows = [];
  const serverBySecond = samplesBySecond(serverMetrics);
  const activityBySecond = samplesBySecond(activityMetrics);
  const loadgenBySecond = samplesBySecond(loadgenMetrics);
  const runtimeBySecond = samplesBySecond(runtimeMetrics);
  let server = serverMetrics[0] ?? {};
  let activity = activityMetrics[0] ?? {};
  let loadgen = loadgenMetrics[0] ?? {};
  let runtime = runtimeMetrics[0] ?? {};

  for (let second = 0; second < length; second += 1) {
    server = serverBySecond.get(second) ?? server;
    activity = activityBySecond.get(second) ?? activity;
    loadgen = loadgenBySecond.get(second) ?? loadgen;
    runtime = runtimeBySecond.get(second) ?? runtime;
    rows.push({
      second,
      phase: loadgen.phase ?? 'idle',
      stageIndex: numberValue(loadgen.stage_index, -1),
      targetConnections: nullableNumber(loadgen.target_connections),
      targetRequestsPerSecond: nullableNumber(loadgen.target_requests_per_second),
      payloadBytes: nullableNumber(loadgen.payload_bytes),
      loadgenConnections: nullableNumber(loadgen.active_connections),
      serverConnections: nullableNumber(activity.active_connections ?? server.tcp_established),
      activeRequests: numberValue(activity.active_requests),
      serverRequestsPerSecond: numberValue(activity.requests_started_per_second),
      serverResponsesPerSecond: numberValue(activity.responses_completed_per_second),
      responses2xxPerSecond: numberValue(activity.responses_2xx_per_second),
      responses4xxPerSecond: numberValue(activity.responses_4xx_per_second),
      responses5xxPerSecond: numberValue(activity.responses_5xx_per_second),
      serverErrorsPerSecond: numberValue(activity.request_errors_per_second),
      loadgenErrorsPerSecond: numberValue(loadgen.errors_per_second),
      dispatchMissesPerSecond: numberValue(loadgen.dispatch_misses_per_second),
      connectionAttemptsPerSecond: numberValue(loadgen.connection_attempts_per_second),
      connectionRetriesPerSecond: numberValue(loadgen.connection_retries_per_second),
      connectionFailuresPerSecond: numberValue(loadgen.connection_failures_per_second),
      loadgenSentPerSecond: numberValue(loadgen.sent_per_second),
      loadgenReceivedPerSecond: numberValue(loadgen.received_per_second),
      p50LatencyMs: numberValue(loadgen.p50_latency_ms),
      p90LatencyMs: numberValue(loadgen.p90_latency_ms),
      p99LatencyMs: numberValue(loadgen.p99_latency_ms),
      maxLatencyMs: numberValue(loadgen.max_latency_ms),
      cpuPercent: numberValue(server.cpu_percent),
      rssMb: numberValue(server.rss_mb ?? bytesToMB(server.rss_bytes)),
      threads: nullableNumber(server.threads),
      openFds: nullableNumber(server.open_fds),
      tcpEstablished: nullableNumber(server.tcp_established),
      tcpListenDropsDelta: numberValue(server.tcp_listen_drops_per_second),
      tcpListenOverflowsDelta: numberValue(server.tcp_listen_overflows_per_second),
      tcpBacklogDropDelta: numberValue(server.tcp_backlog_drop_per_second),
      tcpReqQFullDropDelta: numberValue(server.tcp_req_q_full_drop_per_second),
      tcpSyncookiesSentDelta: numberValue(server.tcp_syncookies_sent_per_second),
      tcpSyncookiesFailedDelta: numberValue(server.tcp_syncookies_failed_per_second),
      heapUsedMb: numberValue(runtime.heap_used_mb),
      heapTotalMb: numberValue(runtime.heap_total_mb),
    });
    const row = rows[rows.length - 1];
    const normalizedConnections = row.serverConnections || row.tcpEstablished || row.loadgenConnections || 0;
    const successfulRps = row.responses2xxPerSecond || row.serverResponsesPerSecond || row.loadgenReceivedPerSecond || 0;
    row.rssMbPer10kConnections = normalizedConnections > 0 ? row.rssMb / (normalizedConnections / 10000) : null;
    row.fdsPerConnection = normalizedConnections > 0 && row.openFds != null ? row.openFds / normalizedConnections : null;
    row.cpuPercentPer10kRps = successfulRps > 0 ? row.cpuPercent / (successfulRps / 10000) : null;
  }

  return rows;
}

function samplesBySecond(samples) {
  const bySecond = new Map();
  for (const sample of samples) {
    const second = Math.max(0, Math.round(Number(sample.timeline_seconds ?? sample.elapsed_seconds ?? 0)));
    bySecond.set(second, sample);
  }
  return bySecond;
}

function findTimelineStart(metadata, ...groups) {
  const timestamps = [];
  const metadataTime = Date.parse(metadata.started_at);
  if (Number.isFinite(metadataTime)) timestamps.push(metadataTime);

  for (const group of groups) {
    for (const sample of group) {
      const time = Date.parse(sample.ts);
      if (Number.isFinite(time)) timestamps.push(time);
    }
  }

  if (timestamps.length === 0) return 0;
  return Math.min(...timestamps);
}

function annotateTimelineSeconds(samples, startTime) {
  for (const sample of samples) {
    const time = Date.parse(sample.ts);
    sample.timeline_seconds = Number.isFinite(time)
      ? Math.max(0, Math.round((time - startTime) / 1000))
      : Number(sample.elapsed_seconds ?? 0);
  }
}

function buildPhaseRanges(samples, maxElapsed) {
  if (!samples.length) return [];

  const ranges = [];
  for (const sample of samples) {
    const name = sample.phase ?? 'unknown';
    const targetConnections = sample.target_connections ?? null;
    const stageIndex = sample.stage_index ?? -1;
    const elapsed = sample.timeline_seconds ?? sample.elapsed_seconds ?? 0;
    const last = ranges[ranges.length - 1];

    if (!last || last.name !== name || last.stageIndex !== stageIndex) {
      ranges.push({ name, stageIndex, targetConnections, start: elapsed, end: elapsed });
    } else {
      last.end = elapsed;
      last.targetConnections = targetConnections ?? last.targetConnections;
    }
  }

  if (ranges.length > 0) {
    ranges[ranges.length - 1].end = maxElapsed;
  }

  return ranges.map((range) => ({
    ...range,
    start: Math.max(0, Math.round(range.start)),
    end: Math.max(0, Math.round(range.end)),
  }));
}

function parseJSONL(text) {
  if (!text.trim()) return [];
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function bytesToMB(value) {
  return Number(value || 0) / 1024 / 1024;
}

function nullableNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function numberValue(value, fallback = 0) {
  const numeric = Number(value ?? fallback);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function runFileURL(runID, fileName) {
  return `runs/${encodeURIComponent(runID)}/${fileName}`;
}

async function fetchJSON(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.json();
}

async function fetchText(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.text();
}
