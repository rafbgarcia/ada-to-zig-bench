export const metricGroups = [
  {
    id: 'traffic',
    title: 'Traffic Throughput',
    description: 'Sent requests and received responses per second across the selected run.',
    unit: '/s',
    series: [
      { key: 'sentPerSecond', label: 'Requests', color: '#2563eb' },
      { key: 'receivedPerSecond', label: 'Responses', color: '#0f766e' },
    ],
  },
  {
    id: 'connections',
    title: 'Connections And CPU',
    description: 'Connection ramp behavior alongside server CPU demand.',
    unit: '',
    dualAxis: true,
    series: [
      { key: 'activeConnections', label: 'Connections', color: '#334155', axis: 'left' },
      { key: 'cpuPercent', label: 'CPU', color: '#b45309', axis: 'right', unit: '%' },
    ],
  },
  {
    id: 'latency',
    title: 'Latency Percentiles',
    description: 'Response-time distribution during active traffic.',
    unit: 'ms',
    series: [
      { key: 'p50LatencyMs', label: 'p50', color: '#14b8a6' },
      { key: 'p90LatencyMs', label: 'p90', color: '#f59e0b' },
      { key: 'p99LatencyMs', label: 'p99', color: '#ef4444' },
      { key: 'maxLatencyMs', label: 'Max', color: '#7c3aed' },
    ],
  },
  {
    id: 'memory',
    title: 'Memory Profile',
    description: 'Server RSS and runtime heap used over time.',
    unit: 'MB',
    series: [
      { key: 'rssMb', label: 'RSS', color: '#0891b2' },
      { key: 'heapUsedMb', label: 'Heap used', color: '#8b5cf6' },
    ],
  },
  {
    id: 'errors',
    title: 'Errors',
    description: 'Load-generator error rate for quick anomaly checks.',
    unit: '/s',
    series: [
      { key: 'errorsPerSecond', label: 'Errors', color: '#dc2626' },
    ],
  },
];

export const phaseColors = {
  baseline: '#eef2f7',
  ramp: '#dbeafe',
  settle: '#dcfce7',
  traffic: '#ffedd5',
  cooldown: '#ede9fe',
  unknown: '#f8fafc',
};

export async function fetchRuns() {
  return fetchJSON('runs.json');
}

export async function loadRun(runID) {
  const [metadata, summary, serverRaw, loadgenRaw, runtimeRaw, eventsRaw] = await Promise.all([
    fetchJSON(runFileURL(runID, 'metadata.json')),
    fetchJSON(runFileURL(runID, 'summary.json')).catch(() => null),
    fetchText(runFileURL(runID, 'server_metrics.jsonl')),
    fetchText(runFileURL(runID, 'loadgen_metrics.jsonl')),
    fetchText(runFileURL(runID, 'runtime_metrics.jsonl')).catch(() => ''),
    fetchText(runFileURL(runID, 'runtime_events.jsonl')).catch(() => ''),
  ]);

  const serverMetrics = parseJSONL(serverRaw);
  const loadgenMetrics = parseJSONL(loadgenRaw);
  const runtimeMetrics = parseJSONL(runtimeRaw).map((sample) => ({
    ...sample,
    heap_used_mb: bytesToMB(sample.heap_used_bytes ?? sample.used_heap_size_bytes ?? 0),
  }));
  const runtimeEvents = parseJSONL(eventsRaw);

  const timelineStart = findTimelineStart(metadata, serverMetrics, loadgenMetrics, runtimeMetrics, runtimeEvents);
  annotateTimelineSeconds(serverMetrics, timelineStart);
  annotateTimelineSeconds(loadgenMetrics, timelineStart);
  annotateTimelineSeconds(runtimeMetrics, timelineStart);
  annotateTimelineSeconds(runtimeEvents, timelineStart);

  const maxElapsed = Math.max(
    0,
    ...serverMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...loadgenMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...runtimeMetrics.map((sample) => sample.timeline_seconds ?? 0),
    ...runtimeEvents.map((event) => event.timeline_seconds ?? 0),
  );
  const phases = buildPhaseRanges(loadgenMetrics, maxElapsed);
  const timeline = buildTimeline({ serverMetrics, loadgenMetrics, runtimeMetrics, maxElapsed });

  return {
    runID,
    metadata,
    summary,
    serverMetrics,
    loadgenMetrics,
    runtimeMetrics,
    runtimeEvents,
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

export function countGCEvents(runtimeEvents, elapsed) {
  return runtimeEvents.filter((event) => event.event === 'gc' && (event.timeline_seconds ?? 0) <= elapsed).length;
}

export function significantGCEvents(runtimeEvents) {
  return runtimeEvents
    .filter((event) => event.event === 'gc')
    .filter((event) => event.kind === 'major' || Number(event.duration_ms ?? 0) >= 5)
    .map((event) => ({
      second: Math.round(Number(event.timeline_seconds ?? 0)),
      kind: event.kind ?? 'gc',
      durationMs: Number(event.duration_ms ?? 0),
    }));
}

function buildTimeline({ serverMetrics, loadgenMetrics, runtimeMetrics, maxElapsed }) {
  const length = Math.max(1, Math.round(maxElapsed)) + 1;
  const rows = [];
  const serverBySecond = samplesBySecond(serverMetrics);
  const loadgenBySecond = samplesBySecond(loadgenMetrics);
  const runtimeBySecond = samplesBySecond(runtimeMetrics);
  let server = serverMetrics[0] ?? {};
  let loadgen = loadgenMetrics[0] ?? {};
  let runtime = runtimeMetrics[0] ?? {};

  for (let second = 0; second < length; second += 1) {
    server = serverBySecond.get(second) ?? server;
    loadgen = loadgenBySecond.get(second) ?? loadgen;
    runtime = runtimeBySecond.get(second) ?? runtime;
    rows.push({
      second,
      phase: loadgen.phase ?? 'idle',
      activeConnections: numberValue(loadgen.active_connections),
      sentPerSecond: numberValue(loadgen.sent_per_second),
      receivedPerSecond: numberValue(loadgen.received_per_second),
      errorsPerSecond: numberValue(loadgen.errors_per_second),
      p50LatencyMs: numberValue(loadgen.p50_latency_ms),
      p90LatencyMs: numberValue(loadgen.p90_latency_ms),
      p99LatencyMs: numberValue(loadgen.p99_latency_ms),
      maxLatencyMs: numberValue(loadgen.max_latency_ms),
      cpuPercent: numberValue(server.cpu_percent),
      rssMb: numberValue(server.rss_mb ?? bytesToMB(server.rss_bytes)),
      heapUsedMb: numberValue(runtime.heap_used_mb),
    });
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
    const elapsed = sample.timeline_seconds ?? sample.elapsed_seconds ?? 0;
    const last = ranges[ranges.length - 1];

    if (!last || last.name !== name) {
      ranges.push({ name, start: elapsed, end: elapsed });
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

function numberValue(value) {
  const numeric = Number(value ?? 0);
  return Number.isFinite(numeric) ? numeric : 0;
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
