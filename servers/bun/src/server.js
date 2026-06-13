import { createWriteStream } from 'node:fs';

const host = process.env.HOST ?? '127.0.0.1';
const ports = parsePorts(process.env.PORTS ?? process.env.PORT ?? '8080');
const runtimeMetricsPath = process.env.RUNTIME_METRICS_PATH;
const runtimeEventsPath = process.env.RUNTIME_EVENTS_PATH;

let activeRequests = 0;
let totalRequests = 0;
let totalErrors = 0;

const runtimeMetrics = runtimeMetricsPath ? createWriteStream(runtimeMetricsPath, { flags: 'a' }) : null;
const runtimeEvents = runtimeEventsPath ? createWriteStream(runtimeEventsPath, { flags: 'a' }) : null;
const startedAt = Date.now();
const servers = ports.map((port) => Bun.serve({ hostname: host, port, fetch: handleRequest }));

for (const port of ports) {
  console.log(`bun HTTP JSON server listening on http://${host}:${port}`);
}

if (runtimeMetrics) {
  writeRuntimeMetric();
  setInterval(writeRuntimeMetric, 1000).unref();
}

if (runtimeEvents) {
  // Bun does not expose a Node-compatible GC performance event stream.
  runtimeEvents.write('');
}

process.once('SIGTERM', shutdown);
process.once('SIGINT', shutdown);

async function handleRequest(req) {
  const url = new URL(req.url);

  if (url.pathname === '/health') {
    return jsonResponse({
      ok: true,
      active_connections: 0,
      active_requests: activeRequests,
      total_requests: totalRequests,
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
  try {
    const request = await req.json();
    if (!Number.isSafeInteger(request.id) || typeof request.payload !== 'string') {
      totalErrors += 1;
      return jsonResponse({ error: 'invalid_request' }, 400);
    }

    totalRequests += 1;
    return jsonResponse(responseFor(request));
  } catch {
    totalErrors += 1;
    return jsonResponse({ error: 'invalid_json' }, 400);
  } finally {
    activeRequests -= 1;
  }
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

function jsonResponse(value, status = 200) {
  return Response.json(value, {
    status,
    headers: {
      connection: 'keep-alive',
    },
  });
}

function runtimeSample() {
  const memory = process.memoryUsage();
  return {
    ts: new Date().toISOString(),
    elapsed_seconds: elapsedSeconds(),
    runtime: 'bun',
    active_connections: 0,
    active_requests: activeRequests,
    total_requests: totalRequests,
    total_errors: totalErrors,
    rss_bytes: memory.rss,
    heap_total_bytes: memory.heapTotal,
    heap_used_bytes: memory.heapUsed,
    external_bytes: memory.external,
    array_buffers_bytes: memory.arrayBuffers,
  };
}

function writeRuntimeMetric() {
  runtimeMetrics.write(`${JSON.stringify(runtimeSample())}\n`);
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
  runtimeMetrics?.end();
  runtimeEvents?.end();
  process.exit(0);
}
