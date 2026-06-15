import http from 'node:http';

const baseUrls = process.argv.slice(2);

if (baseUrls.length === 0) {
  throw new Error('usage: scripts/check-http-json-server.mjs <base-url> [base-url ...]');
}

for (const baseUrl of baseUrls) {
  await checkServer(baseUrl);
}

async function checkServer(baseUrl) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });

  try {
    const health = expectJSON(await request(baseUrl, { agent, path: '/health' }), 200, '/health');
    assert(health.ok === true, `${baseUrl} /health should return ok=true`);

    const runtime = expectJSON(await request(baseUrl, { agent, path: '/runtime' }), 200, '/runtime');
    assert(typeof runtime.runtime === 'string' && runtime.runtime.length > 0, `${baseUrl} /runtime should identify the runtime`);

    await expectJSONPost(baseUrl, agent, { id: 0, payload: '' });
    await expectJSONPost(baseUrl, agent, { id: 7, payload: 'hello' });
    await expectJSONPost(baseUrl, agent, { id: 42, payload: 'ola mundo' });
    await expectJSONPost(baseUrl, agent, { id: 99, payload: 'payload with newline\nand tab\tcharacters' });

    expectJSON(await request(baseUrl, { agent, path: '/json' }), 404, 'GET /json');
    expectJSON(await request(baseUrl, { agent, path: '/missing' }), 404, 'GET /missing');
    expectJSON(await postRaw(baseUrl, agent, '{'), 400, 'invalid JSON');
    expectJSON(await postJSON(baseUrl, agent, { id: -1, payload: 'x' }), 400, 'negative id');
    expectJSON(await postJSON(baseUrl, agent, { id: 1.5, payload: 'x' }), 400, 'fractional id');
    expectJSON(await postJSON(baseUrl, agent, { id: 1 }), 400, 'missing payload');
    expectJSON(await postJSON(baseUrl, agent, { id: 1, payload: 123 }), 400, 'non-string payload');
  } finally {
    agent.destroy();
  }
}

async function expectJSONPost(baseUrl, agent, message) {
  const response = expectJSON(await postJSON(baseUrl, agent, message), 200, `POST /json id=${message.id}`);
  const payloadBytes = Buffer.from(message.payload, 'utf8');

  assert(response.id === message.id, `${baseUrl} response id mismatch: ${response.id} !== ${message.id}`);
  assert(response.len === payloadBytes.byteLength, `${baseUrl} response len mismatch: ${response.len} !== ${payloadBytes.byteLength}`);
  assert(response.checksum === checksum(payloadBytes), `${baseUrl} response checksum mismatch: ${response.checksum} !== ${checksum(payloadBytes)}`);
}

function expectJSON(response, statusCode, label) {
  assert(response.statusCode === statusCode, `${label} expected status ${statusCode}, got ${response.statusCode}: ${response.body.toString('utf8')}`);

  const contentType = String(response.headers['content-type'] ?? '');
  assert(contentType.toLowerCase().includes('application/json'), `${label} expected application/json content-type, got ${contentType || '<missing>'}`);

  const contentLength = response.headers['content-length'];
  assert(contentLength !== undefined, `${label} expected content-length header`);
  assert(Number(contentLength) === response.body.byteLength, `${label} content-length ${contentLength} does not match body length ${response.body.byteLength}`);

  try {
    return JSON.parse(response.body.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} returned invalid JSON: ${error.message}`);
  }
}

function postJSON(baseUrl, agent, value) {
  return postRaw(baseUrl, agent, JSON.stringify(value));
}

function postRaw(baseUrl, agent, body) {
  const bytes = Buffer.from(body, 'utf8');
  return request(baseUrl, {
    agent,
    path: '/json',
    method: 'POST',
    body: bytes,
    headers: {
      'content-type': 'application/json',
      'content-length': bytes.byteLength,
    },
  });
}

function request(baseUrl, options) {
  const url = new URL(options.path, baseUrl);

  return new Promise((resolve, reject) => {
    const req = http.request({
      agent: options.agent,
      hostname: url.hostname,
      port: url.port,
      path: `${url.pathname}${url.search}`,
      method: options.method ?? 'GET',
      headers: {
        host: url.host,
        connection: 'keep-alive',
        ...(options.headers ?? {}),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks),
        });
      });
    });

    req.on('error', reject);
    req.end(options.body);
  });
}

function checksum(payloadBytes) {
  let value = 2166136261;
  for (const byte of payloadBytes) {
    value ^= byte;
    value = Math.imul(value, 16777619) >>> 0;
  }
  return value;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
