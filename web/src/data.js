export const metricGroups = [
  {
    id: 'work',
    title: 'Request Throughput',
    description: 'Client-observed schedule, dispatch, and completion rates derived from cumulative load-generator counters.',
    unit: '/s',
    series: [
      { key: 'targetRequestsPerSecond', label: 'Target', color: '#64748b', unit: '/s' },
      { key: 'loadgenScheduledPerSecond', label: 'Scheduled', color: '#2563eb', unit: '/s' },
      { key: 'loadgenDispatchedPerSecond', label: 'Dispatched', color: '#d97706', unit: '/s' },
      { key: 'loadgenReceivedPerSecond', label: 'Completed', color: '#0f766e', unit: '/s' },
      { key: 'dispatchMissesPerSecond', label: 'Missed slots', color: '#be123c', unit: '/s' },
    ],
  },
  {
    id: 'inflight',
    title: 'In-Flight Requests',
    description: 'Current requests active in the load generator and measured server process.',
    unit: '',
    series: [
      { key: 'loadgenInFlight', label: 'Loadgen in flight', color: '#7c3aed' },
      { key: 'activeRequests', label: 'Server active', color: '#0f766e' },
    ],
  },
  {
    id: 'latency',
    title: 'Loadgen Latency',
    description: 'Client-observed request latency percentiles from the load generator.',
    unit: 'ms',
    series: [
      { key: 'p50LatencyMs', label: 'p50', color: '#14b8a6', unit: 'ms' },
      { key: 'p90LatencyMs', label: 'p90', color: '#2563eb', unit: 'ms' },
      { key: 'p99LatencyMs', label: 'p99', color: '#d97706', unit: 'ms' },
      { key: 'maxLatencyMs', label: 'max', color: '#be123c', unit: 'ms' },
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
  setup: '#64748b',
  warmup: '#d97706',
  payload_sweep: '#0d9488',
  unknown: '#cbd5e1',
};

export const phaseLabels = {
  setup: 'Setup',
  warmup: 'Warmup',
  payload_sweep: 'Payload sweep',
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

  const serverMetricsRaw = parseJSONL(serverRaw);
  const activityMetricsRaw = parseJSONL(activityRaw);
  const loadgenMetricsRaw = parseJSONL(loadgenRaw);
  const runtimeMetrics = parseJSONL(runtimeRaw).map((sample) => ({
    ...sample,
    heap_used_mb: bytesToMB(sample.heap_used_bytes ?? sample.used_heap_size_bytes ?? 0),
    heap_total_mb: bytesToMB(sample.heap_total_bytes ?? sample.total_heap_size_bytes ?? 0),
  }));
  const serverEvents = parseJSONL(serverEventsRaw);
  const loadgenErrors = parseJSONL(loadgenErrorsRaw);

  const timelineStart = findTimelineStart(metadata, serverMetricsRaw, activityMetricsRaw, loadgenMetricsRaw, runtimeMetrics, serverEvents, loadgenErrors);
  for (const group of [serverMetricsRaw, activityMetricsRaw, loadgenMetricsRaw, runtimeMetrics, serverEvents, loadgenErrors]) {
    annotateTimelineSeconds(group, timelineStart);
  }

  const serverMetricsWithRates = withDerivedServerRates(serverMetricsRaw);
  const activityMetrics = withDerivedActivityRates(activityMetricsRaw);
  const loadgenMetrics = withDerivedLoadgenRates(loadgenMetricsRaw);

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
  return dedupeSamplesByTime(samples).map((sample) => {
    const deltaSeconds = secondsBetween(previous, sample);
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
  return dedupeSamplesByTime(samples).map((sample) => {
    const deltaSeconds = secondsBetween(previous, sample);
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

function withDerivedLoadgenRates(samples) {
  let previous = null;
  return dedupeSamplesByTime(samples).map((sample) => {
    const deltaSeconds = secondsBetween(previous, sample);
    const next = {
      ...sample,
      scheduled_per_second: sample.scheduled != null
        ? derivedRate(sample, previous, 'scheduled', deltaSeconds, sample.scheduled_per_second)
        : numberValue(sample.scheduled_per_second, numberValue(sample.target_requests_per_second)),
      dispatched_per_second: sample.dispatched != null
        ? derivedRate(sample, previous, 'dispatched', deltaSeconds, sample.dispatched_per_second ?? sample.sent_per_second)
        : numberValue(sample.dispatched_per_second, numberValue(sample.sent_per_second)),
      sent_per_second: derivedRate(sample, previous, 'sent', deltaSeconds, sample.sent_per_second),
      received_per_second: derivedRate(sample, previous, 'received', deltaSeconds, sample.received_per_second),
      errors_per_second: derivedRate(sample, previous, 'errors', deltaSeconds, sample.errors_per_second),
      dispatch_misses_per_second: derivedRate(sample, previous, 'dispatch_misses', deltaSeconds, sample.dispatch_misses_per_second),
    };
    previous = sample;
    return next;
  });
}

function dedupeSamplesByTime(samples) {
  const next = [];
  for (const sample of samples) {
    const last = next[next.length - 1];
    if (!last || sampleTimeMs(last) !== sampleTimeMs(sample)) {
      next.push(sample);
      continue;
    }
    next[next.length - 1] = mergeDuplicateSample(last, sample);
  }
  return next;
}

function mergeDuplicateSample(previous, sample) {
  const merged = { ...previous, ...sample };
  for (const [key, value] of Object.entries(previous)) {
    if (!key.endsWith('_total') && !['scheduled', 'dispatched', 'sent', 'received', 'errors', 'dispatch_misses'].includes(key)) {
      continue;
    }
    const left = Number(value);
    const right = Number(sample[key]);
    if (Number.isFinite(left) && Number.isFinite(right)) merged[key] = Math.max(left, right);
  }
  return merged;
}

function secondsBetween(previous, sample) {
  if (!previous) return 1;
  return Math.max(0.001, (sampleTimeMs(sample) - sampleTimeMs(previous)) / 1000);
}

function sampleTimeMs(sample) {
  const timeline = Number(sample.timeline_ms);
  if (Number.isFinite(timeline)) return timeline;
  const elapsedMs = Number(sample.elapsed_ms);
  if (Number.isFinite(elapsedMs)) return elapsedMs;
  const parsed = Date.parse(sample.ts);
  if (Number.isFinite(parsed)) return parsed;
  return Number(sample.timeline_seconds ?? sample.elapsed_seconds ?? 0) * 1000;
}

function derivedRate(sample, previous, key, deltaSeconds, fallback) {
  if (previous && sample[key] != null && previous[key] != null) {
    return delta(sample, previous, key) / deltaSeconds;
  }
  return numberValue(fallback);
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
      phase: loadgen.phase ?? 'setup',
      stageIndex: numberValue(loadgen.stage_index, -1),
      targetRequestsPerSecond: nullableNumber(loadgen.target_requests_per_second),
      payloadBytes: nullableNumber(loadgen.payload_bytes),
      activeRequests: numberValue(activity.active_requests),
      loadgenInFlight: numberValue(loadgen.in_flight, Math.max(0, numberValue(loadgen.sent) - numberValue(loadgen.received) - numberValue(loadgen.errors))),
      serverRequestsPerSecond: numberValue(activity.requests_started_per_second),
      serverResponsesPerSecond: numberValue(activity.responses_completed_per_second),
      responses2xxPerSecond: numberValue(activity.responses_2xx_per_second),
      responses4xxPerSecond: numberValue(activity.responses_4xx_per_second),
      responses5xxPerSecond: numberValue(activity.responses_5xx_per_second),
      serverErrorsPerSecond: numberValue(activity.request_errors_per_second),
      loadgenErrorsPerSecond: numberValue(loadgen.errors_per_second),
      dispatchMissesPerSecond: numberValue(loadgen.dispatch_misses_per_second),
      loadgenScheduledPerSecond: numberValue(loadgen.scheduled_per_second, numberValue(loadgen.target_requests_per_second)),
      loadgenDispatchedPerSecond: numberValue(loadgen.dispatched_per_second, numberValue(loadgen.sent_per_second)),
      loadgenSentPerSecond: numberValue(loadgen.sent_per_second),
      loadgenReceivedPerSecond: numberValue(loadgen.received_per_second),
      p50LatencyMs: latencyValue(loadgen, 'p50_latency_ms'),
      p90LatencyMs: latencyValue(loadgen, 'p90_latency_ms'),
      p99LatencyMs: latencyValue(loadgen, 'p99_latency_ms'),
      maxLatencyMs: latencyValue(loadgen, 'max_latency_ms'),
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
    const successfulRps = row.responses2xxPerSecond || row.serverResponsesPerSecond || row.loadgenReceivedPerSecond || 0;
    row.cpuPercentPer10kRps = successfulRps > 0 ? row.cpuPercent / (successfulRps / 10000) : null;
  }

  return rows;
}

function samplesBySecond(samples) {
  const bySecond = new Map();
  for (const sample of samples) {
    const second = Math.max(0, Math.round(Number(sample.timeline_seconds ?? sample.elapsed_seconds ?? 0)));
    const current = bySecond.get(second);
    bySecond.set(second, chooseSampleForSecond(current, sample));
  }
  return bySecond;
}

function chooseSampleForSecond(current, sample) {
  if (!current) return sample;
  return sampleProgress(sample) >= sampleProgress(current) ? sample : current;
}

function sampleProgress(sample) {
  return Math.max(
    numberValue(sample.responses_completed_total),
    numberValue(sample.responses_2xx_total),
    numberValue(sample.received),
    numberValue(sample.sent),
    numberValue(sample.dispatched),
    numberValue(sample.scheduled),
  );
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
    if (Number.isFinite(time)) {
      sample.timeline_ms = Math.max(0, time - startTime);
      sample.timeline_seconds = Math.max(0, Math.round(sample.timeline_ms / 1000));
    } else {
      sample.timeline_ms = Number(sample.elapsed_ms ?? Number(sample.elapsed_seconds ?? 0) * 1000);
      sample.timeline_seconds = Math.max(0, Math.round(sample.timeline_ms / 1000));
    }
  }
}

function buildPhaseRanges(samples, maxElapsed) {
  if (!samples.length) return [];

  const ranges = [];
  for (const sample of samples) {
    const name = sample.phase ?? 'unknown';
    const stageIndex = sample.stage_index ?? -1;
    const elapsed = sample.timeline_seconds ?? sample.elapsed_seconds ?? 0;
    const last = ranges[ranges.length - 1];

    if (!last || last.name !== name || last.stageIndex !== stageIndex) {
      ranges.push({ name, stageIndex, start: elapsed, end: elapsed });
    } else {
      last.end = elapsed;
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

function latencyValue(sample, key) {
  const value = nullableNumber(sample[key]);
  if (value !== 0) return value;
  return numberValue(sample.received_per_second) > 0 ? value : null;
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
