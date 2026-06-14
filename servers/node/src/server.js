import http from 'node:http';
import { createWriteStream } from 'node:fs';
import v8 from 'node:v8';
import { constants, PerformanceObserver } from 'node:perf_hooks';

const host = process.env.HOST ?? '127.0.0.1';
const ports = parsePorts(process.env.PORTS ?? process.env.PORT ?? '8080');
const activityMetricsPath = process.env.ACTIVITY_METRICS_PATH;
const serverEventsPath = process.env.SERVER_EVENTS_PATH;
const runtimeMetricsPath = process.env.RUNTIME_METRICS_PATH;
const runtimeEventsPath = process.env.RUNTIME_EVENTS_PATH;

let activeRequests = 0;
let requestsStarted = 0;
let responsesCompleted = 0;
let totalErrors = 0;
let acceptedConnections = 0;
let closedConnections = 0;
let responses2xx = 0;
let responses4xx = 0;
let responses5xx = 0;
const sockets = new Set();

const activityMetrics = activityMetricsPath ? createWriteStream(activityMetricsPath, { flags: 'a' }) : null;
const serverEvents = serverEventsPath ? createWriteStream(serverEventsPath, { flags: 'a' }) : null;
const runtimeMetrics = runtimeMetricsPath ? createWriteStream(runtimeMetricsPath, { flags: 'a' }) : null;
const runtimeEvents = runtimeEventsPath ? createWriteStream(runtimeEventsPath, { flags: 'a' }) : null;
const startedAt = Date.now();
const servers = ports.map((port) => createServer(port));

for (const server of servers) {
  server.listen(server.port, host, () => {
    console.log(`node HTTP JSON server listening on http://${host}:${server.port}`);
  });
}

if (activityMetrics) {
  writeActivityMetric();
  setInterval(writeActivityMetric, 1000).unref();
}

if (runtimeMetrics) {
  writeRuntimeMetric();
  setInterval(writeRuntimeMetric, 1000).unref();
}

if (runtimeEvents) {
  const observer = new PerformanceObserver((items) => {
    for (const entry of items.getEntries()) {
      const kindCode = entry.detail?.kind ?? null;
      const flags = entry.detail?.flags ?? null;
      writeRuntimeEvent({
        ts: new Date().toISOString(),
        elapsed_seconds: elapsedSeconds(),
        runtime: 'node',
        event: 'gc',
        kind: gcKindName(kindCode),
        kind_code: kindCode,
        flags,
        duration_ms: entry.duration,
      });
    }
  });
  observer.observe({ entryTypes: ['gc'] });
}

process.once('SIGTERM', shutdown);
process.once('SIGINT', shutdown);

function createServer(port) {
  const server = http.createServer(async (req, res) => {
    if (req.url === '/health') {
      writeJSON(res, 200, {
        ok: true,
        active_connections: sockets.size,
        active_requests: activeRequests,
        accepted_connections_total: acceptedConnections,
        closed_connections_total: closedConnections,
        requests_started_total: requestsStarted,
        responses_completed_total: responsesCompleted,
        total_errors: totalErrors,
      });
      return;
    }

    if (req.url === '/runtime') {
      writeJSON(res, 200, runtimeSample());
      return;
    }

    if (req.url !== '/json' || req.method !== 'POST') {
      writeJSON(res, 404, { error: 'not_found' });
      return;
    }

    activeRequests += 1;
    requestsStarted += 1;
    try {
      const request = JSON.parse(await readBody(req, 1 << 20));
      if (!Number.isSafeInteger(request.id) || typeof request.payload !== 'string') {
        totalErrors += 1;
        recordResponse(400);
        writeServerEvent('request_error', { reason: 'invalid_request', status_code: 400 });
        writeJSON(res, 400, { error: 'invalid_request' });
        return;
      }

      recordResponse(200);
      writeJSON(res, 200, responseFor(request));
    } catch (error) {
      totalErrors += 1;
      recordResponse(400);
      writeServerEvent('request_error', { reason: error.message === 'body_too_large' ? 'body_too_large' : 'invalid_json', status_code: 400 });
      writeJSON(res, 400, { error: 'invalid_json' });
    } finally {
      activeRequests -= 1;
    }
  });

  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  server.requestTimeout = 30_000;
  server.port = port;

  server.on('connection', (socket) => {
    sockets.add(socket);
    acceptedConnections += 1;
    socket.on('close', () => {
      sockets.delete(socket);
      closedConnections += 1;
    });
  });

  return server;
}

function readBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];

    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error('body_too_large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function responseFor(request) {
  const payload = request.payload;
  let checksum = 2166136261;
  for (let index = 0; index < payload.length; index += 1) {
    checksum ^= payload.charCodeAt(index);
    checksum = Math.imul(checksum, 16777619) >>> 0;
  }

  return {
    id: request.id,
    len: Buffer.byteLength(payload),
    checksum,
  };
}

function writeJSON(res, statusCode, value) {
  const body = JSON.stringify(value);
  res.writeHead(statusCode, {
    'connection': 'keep-alive',
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function recordResponse(statusCode) {
  responsesCompleted += 1;
  if (statusCode >= 200 && statusCode < 300) responses2xx += 1;
  else if (statusCode >= 400 && statusCode < 500) responses4xx += 1;
  else if (statusCode >= 500) responses5xx += 1;
}

function activitySample() {
  return {
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    active_connections: sockets.size,
    accepted_connections_total: acceptedConnections,
    closed_connections_total: closedConnections,
    active_requests: activeRequests,
    requests_started_total: requestsStarted,
    responses_completed_total: responsesCompleted,
    responses_2xx_total: responses2xx,
    responses_4xx_total: responses4xx,
    responses_5xx_total: responses5xx,
    request_errors_total: totalErrors,
  };
}

function runtimeSample() {
  const memory = process.memoryUsage();
  const heap = v8.getHeapStatistics();
  return {
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    runtime: 'node',
    rss_bytes: memory.rss,
    heap_total_bytes: memory.heapTotal,
    heap_used_bytes: memory.heapUsed,
    external_bytes: memory.external,
    array_buffers_bytes: memory.arrayBuffers,
    total_heap_size_bytes: heap.total_heap_size,
    used_heap_size_bytes: heap.used_heap_size,
    heap_size_limit_bytes: heap.heap_size_limit,
    malloced_memory_bytes: heap.malloced_memory,
    external_memory_bytes: heap.external_memory,
    number_of_native_contexts: heap.number_of_native_contexts,
    number_of_detached_contexts: heap.number_of_detached_contexts,
  };
}

function writeActivityMetric() {
  activityMetrics.write(`${JSON.stringify(activitySample())}\n`);
}

function writeRuntimeMetric() {
  runtimeMetrics.write(`${JSON.stringify(runtimeSample())}\n`);
}

function writeServerEvent(event, fields = {}) {
  if (!serverEvents) return;
  serverEvents.write(`${JSON.stringify({
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    event,
    ...fields,
  })}\n`);
}

function writeRuntimeEvent(event) {
  runtimeEvents.write(`${JSON.stringify(event)}\n`);
}

function elapsedSeconds() {
  return Math.floor((Date.now() - startedAt) / 1000);
}

function parsePorts(value) {
  const parsed = value.split(',')
    .map((item) => Number(item.trim()))
    .filter((item) => Number.isInteger(item) && item > 0 && item < 65536);

  if (parsed.length === 0) throw new Error('PORTS must contain at least one TCP port');
  return [...new Set(parsed)];
}

function gcKindName(kindCode) {
  switch (kindCode) {
    case constants.NODE_PERFORMANCE_GC_MAJOR:
      return 'major';
    case constants.NODE_PERFORMANCE_GC_MINOR:
      return 'minor';
    case constants.NODE_PERFORMANCE_GC_INCREMENTAL:
      return 'incremental';
    case constants.NODE_PERFORMANCE_GC_WEAKCB:
      return 'weakcb';
    default:
      return 'unknown';
  }
}

function shutdown() {
  for (const socket of sockets) socket.destroy();
  let remaining = servers.length;
  const done = () => {
    remaining -= 1;
    if (remaining <= 0) {
      runtimeMetrics?.end();
      runtimeEvents?.end();
      activityMetrics?.end();
      serverEvents?.end();
      process.exit(0);
    }
  };

  for (const server of servers) server.close(done);
  setTimeout(() => process.exit(0), 1000).unref();
}
