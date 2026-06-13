import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.join(__dirname, 'dist');
const port = Number(process.env.PORT ?? 5173);
const host = process.env.HOST ?? '127.0.0.1';

const contentTypes = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.jsonl', 'application/x-ndjson; charset=utf-8'],
]);

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
    const pathname = decodeURIComponent(url.pathname);
    const asset = pathname === '/' ? '/index.html' : pathname;
    const filePath = path.normalize(path.join(distDir, asset));

    if (!filePath.startsWith(`${distDir}${path.sep}`)) {
      writeText(res, 400, 'invalid path');
      return;
    }

    await serveFile(filePath, res);
  } catch (error) {
    if (error.code === 'ENOENT') {
      writeText(res, 404, 'not found');
      return;
    }

    writeText(res, 500, String(error?.message ?? error));
  }
});

server.listen(port, host, () => {
  console.log(`replay UI preview listening on http://${host}:${port}`);
});

async function serveFile(filePath, res) {
  const data = await readFile(filePath);
  const ext = path.extname(filePath);
  res.writeHead(200, { 'content-type': contentTypes.get(ext) ?? 'application/octet-stream' });
  res.end(data);
}

function writeText(res, statusCode, body) {
  res.writeHead(statusCode, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(body);
}
