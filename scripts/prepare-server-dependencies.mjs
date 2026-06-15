import { readdir, readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';

const rootDir = path.resolve(import.meta.dirname, '..');
const serversDir = path.join(rootDir, 'servers');
const entries = await readdir(serversDir, { withFileTypes: true });

for (const entry of entries) {
  if (!entry.isDirectory()) continue;

  const serverDir = path.join(serversDir, entry.name);
  const manifestPath = path.join(serverDir, 'bench.json');
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') continue;
    throw error;
  }

  const command = String(manifest.install ?? '').trim();
  if (!command) continue;

  console.log(`installing ${entry.name}: ${command}`);
  await run(command, serverDir);
}

function run(command, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', ['-c', command], {
      cwd,
      stdio: 'inherit',
      env: process.env,
    });

    child.on('error', reject);
    child.on('exit', (code, signal) => {
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(signal ? `${command} terminated by ${signal}` : `${command} failed with exit code ${code}`));
    });
  });
}
