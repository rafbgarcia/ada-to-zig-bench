import { createWriteStream } from 'node:fs';

const host = process.env.HOST ?? '127.0.0.1';
const ports = parsePorts(process.env.PORTS ?? process.env.PORT ?? '8080');
const activityMetricsPath = process.env.ACTIVITY_METRICS_PATH;
const serverEventsPath = process.env.SERVER_EVENTS_PATH;
const runtimeMetricsPath = process.env.RUNTIME_METRICS_PATH;

let activeRequests = 0;
let requestsStarted = 0;
let responsesCompleted = 0;
let totalErrors = 0;
let responses2xx = 0;
let responses4xx = 0;
let responses5xx = 0;

const activityMetrics = activityMetricsPath ? createWriteStream(activityMetricsPath, { flags: 'a' }) : null;
const serverEvents = serverEventsPath ? createWriteStream(serverEventsPath, { flags: 'a' }) : null;
const runtimeMetrics = runtimeMetricsPath ? createWriteStream(runtimeMetricsPath, { flags: 'a' }) : null;
const startedAt = Date.now();
const servers = ports.map((port) => Bun.serve({ hostname: host, port, idleTimeout: 120, fetch: handleRequest }));

for (const port of ports) {
  console.log(`bun HTTP JSON server listening on http://${host}:${port}`);
}

if (activityMetrics) {
  writeActivityMetric();
  setInterval(writeActivityMetric, 1000).unref();
}

if (runtimeMetrics) {
  writeRuntimeMetric();
  setInterval(writeRuntimeMetric, 1000).unref();
}

process.once('SIGTERM', shutdown);
process.once('SIGINT', shutdown);

async function handleRequest(req) {
  const url = new URL(req.url);

  if (url.pathname === '/health') {
    return jsonResponse({
      ok: true,
      active_requests: activeRequests,
      requests_started_total: requestsStarted,
      responses_completed_total: responsesCompleted,
      total_errors: totalErrors,
    });
  }

  if (url.pathname === '/runtime') {
    return jsonResponse(runtimeSample());
  }

  if (url.pathname !== '/json' || req.method !== 'POST') {
    return jsonResponse({ error: 'not_found' }, 404);
  }

  activeRequests += 1;
  requestsStarted += 1;
  try {
    const body = await req.text();
    const request = JSON.parse(body);
    if (!Number.isSafeInteger(request.id) || request.id < 0 || typeof request.payload !== 'string') {
      totalErrors += 1;
      recordResponse(400);
      writeServerEvent('request_error', { reason: 'invalid_request', status_code: 400 });
      return jsonResponse({ error: 'invalid_request' }, 400);
    }

    recordResponse(200);
    return jsonResponse(responseFor(request));
  } catch (error) {
    totalErrors += 1;
    recordResponse(400);
    writeServerEvent('request_error', { reason: 'invalid_json', status_code: 400 });
    return jsonResponse({ error: 'invalid_json' }, 400);
  } finally {
    activeRequests -= 1;
  }
}

function responseFor(request) {
  const payload = Buffer.from(request.payload);
  let checksum = 2166136261;
  for (let index = 0; index < payload.byteLength; index += 1) {
    checksum ^= payload[index];
    checksum = Math.imul(checksum, 16777619) >>> 0;
  }

  return {
    id: request.id,
    len: payload.byteLength,
    checksum,
  };
}

function jsonResponse(value, status = 200) {
  const body = JSON.stringify(value);
  return new Response(body, {
    status,
    headers: {
      'connection': 'keep-alive',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body).toString(),
    },
  });
}

function recordResponse(status) {
  responsesCompleted += 1;
  if (status >= 200 && status < 300) responses2xx += 1;
  else if (status >= 400 && status < 500) responses4xx += 1;
  else if (status >= 500) responses5xx += 1;
}

function activitySample() {
  return {
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    active_connections: null,
    accepted_connections_total: null,
    closed_connections_total: null,
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
  return {
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    runtime: 'bun',
    rss_bytes: memory.rss,
    heap_total_bytes: memory.heapTotal,
    heap_used_bytes: memory.heapUsed,
    external_bytes: memory.external,
    array_buffers_bytes: memory.arrayBuffers,
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

function shutdown() {
  for (const server of servers) server.stop();
  activityMetrics?.end();
  serverEvents?.end();
  runtimeMetrics?.end();
  process.exit(0);
}
