import { mkdir, readdir, readFile, rm, copyFile, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const serversDir = path.join(rootDir, 'servers');
const distDir = path.join(__dirname, 'dist');
const distRunsDir = path.join(distDir, 'runs');
const runFiles = [
  'metadata.json',
  'summary.json',
  'server_metrics.jsonl',
  'activity_metrics.jsonl',
  'server_events.jsonl',
  'loadgen_metrics.jsonl',
  'loadgen_errors.jsonl',
  'runtime_metrics.jsonl',
];

await rm(distDir, { recursive: true, force: true });
await runViteBuild();
await mkdir(distRunsDir, { recursive: true });

const runs = await collectRuns();
await writeJSON(path.join(distDir, 'runs.json'), runs);

console.log(`Built ${path.relative(rootDir, distDir)} with ${runs.length} run${runs.length === 1 ? '' : 's'}.`);

async function collectRuns() {
  let entries = [];
  try {
    entries = await readdir(serversDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const runs = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !isSafePathSegment(entry.name)) continue;

    const sourceRunDir = path.join(serversDir, entry.name, 'benchmark');

    try {
      const metadata = JSON.parse(await readFile(path.join(sourceRunDir, 'metadata.json'), 'utf8'));
      const runID = isSafePathSegment(metadata.id) ? metadata.id : entry.name;
      const distRunDir = path.join(distRunsDir, runID);
      await mkdir(distRunDir, { recursive: true });
      await copyRunFiles(sourceRunDir, distRunDir);
      runs.push({ id: runID, metadata });
    } catch (error) {
      if (error.code !== 'ENOENT') console.warn(`Skipping ${entry.name}: ${error.message}`);
    }
  }

  runs.sort((a, b) => String(b.metadata.started_at).localeCompare(String(a.metadata.started_at)));
  return runs;
}

async function copyRunFiles(sourceRunDir, distRunDir) {
  await Promise.all(runFiles.map(async (fileName) => {
    try {
      await copyFile(path.join(sourceRunDir, fileName), path.join(distRunDir, fileName));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }));
}

async function readOptionalJSON(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function writeJSON(filePath, value) {
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function isSafePathSegment(value) {
  return /^[A-Za-z0-9_.-]+$/.test(value);
}

function runViteBuild() {
  return new Promise((resolve, reject) => {
    const viteBin = path.join(__dirname, 'node_modules', '.bin', process.platform === 'win32' ? 'vite.cmd' : 'vite');
    const child = spawn(viteBin, ['build'], {
      cwd: __dirname,
      stdio: 'inherit',
      env: process.env,
    });

    child.on('error', reject);
    child.on('exit', (code, signal) => {
      if (code === 0) {
        resolve();
        return;
      }

      reject(new Error(signal ? `vite build terminated by ${signal}` : `vite build failed with exit code ${code}`));
    });
  });
}
