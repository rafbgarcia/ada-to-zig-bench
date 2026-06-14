#!/usr/bin/env bash
set -euo pipefail

SERVER_NAME="${1:-node}"
CONNECTION_TARGETS="${2:-${BENCHMARK_CONNECTIONS:-1000000}}"
PAYLOAD_BYTES="${3:-256}"
REQUESTS_PER_SECOND="${4:-100000}"
TRAFFIC_SECONDS="${5:-10}"
PAYLOAD_SWEEP_BYTES="${PAYLOAD_SWEEP_BYTES:-256 1024 4096 16384}"
PAYLOAD_SWEEP_SECONDS="${PAYLOAD_SWEEP_SECONDS:-5}"
BASELINE_SECONDS="${BASELINE_SECONDS:-0}"
TARGET_CONNECTION_RATE="${TARGET_CONNECTION_RATE:-50000}"
CONNECTION_RETRIES="${CONNECTION_RETRIES:-3}"
CONNECTION_RETRY_DELAY="${CONNECTION_RETRY_DELAY:-1s}"
SETTLE_SECONDS="${SETTLE_SECONDS:-0}"
STABILIZE_SECONDS="${STABILIZE_SECONDS:-0}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"

HOST="${HOST:-127.0.0.1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$ROOT_DIR/.tmp"
LOADGEN_BIN="$TMP_DIR/loadgen"
COLLECTOR_BIN="$TMP_DIR/collector"
MANIFEST="$ROOT_DIR/servers/$SERVER_NAME/bench.json"

port_range_csv() {
  local start="$1"
  local count="$2"
  local ports=()
  local index

  for (( index = 0; index < count; index++ )); do
    ports+=("$((start + index))")
  done

  local IFS=,
  printf '%s' "${ports[*]}"
}

DEFAULT_SERVER_PORTS="$(port_range_csv 8080 32)"

if [[ ! -f "$MANIFEST" ]]; then
  echo "unknown server '$SERVER_NAME'; expected servers/<name>/bench.json" >&2
  exit 1
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_command go
require_command node

SERVER_DIR="$ROOT_DIR/servers/$SERVER_NAME"
SERVER_ID="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.id || process.argv[2]);" "$MANIFEST" "$SERVER_NAME")"
SERVER_LANGUAGE="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.language || '');" "$MANIFEST")"
SERVER_RUNTIME="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.runtime || '');" "$MANIFEST")"
SERVER_SUITE="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.suite || 'http-json');" "$MANIFEST")"
SERVER_COMMAND_DISPLAY="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.run || '');" "$MANIFEST")"
SERVER_PORTS="$(DEFAULT_SERVER_PORTS="$DEFAULT_SERVER_PORTS" node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log((m.ports || process.env.DEFAULT_SERVER_PORTS.split(',').map(Number)).join(','));" "$MANIFEST")"
INSTALL_COMMAND="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.install || '');" "$MANIFEST")"

if [[ -z "$SERVER_COMMAND_DISPLAY" ]]; then
  echo "servers/$SERVER_NAME/bench.json is missing a run command" >&2
  exit 1
fi

if [[ -n "$INSTALL_COMMAND" ]]; then
  echo "installing dependencies for $SERVER_NAME"
  (cd "$SERVER_DIR" && bash -lc "$INSTALL_COMMAND")
fi

RUN_DIR="$SERVER_DIR/benchmark"
RUN_WORK_DIR="$TMP_DIR/${SERVER_NAME}-benchmark"
mkdir -p "$TMP_DIR"
rm -rf "$RUN_WORK_DIR"
mkdir -p "$RUN_WORK_DIR"

IFS=',' read -r -a PORT_ARRAY <<<"$SERVER_PORTS"
URLS=""
for port in "${PORT_ARRAY[@]}"; do
  port="${port//[[:space:]]/}"
  [[ -n "$port" ]] || continue
  if [[ -n "$URLS" ]]; then URLS+=","; fi
  URLS+="http://$HOST:$port/json"
done

FIRST_PORT="${PORT_ARRAY[0]//[[:space:]]/}"
MAX_CONNECTIONS="$(CONNECTION_TARGETS="$CONNECTION_TARGETS" node <<'NODE'
const targets = process.env.CONNECTION_TARGETS.split(/[\s,]+/).filter(Boolean).map(Number);
if (targets.length === 0 || targets.some((value) => !Number.isInteger(value) || value <= 0)) process.exit(1);
console.log(Math.max(...targets));
NODE
)"
SERVER_PID=""
COLLECTOR_PID=""

cleanup() {
  if [[ -n "$COLLECTOR_PID" ]] && kill -0 "$COLLECTOR_PID" 2>/dev/null; then
    kill "$COLLECTOR_PID" 2>/dev/null || true
    wait "$COLLECTOR_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
git_commit="$(git rev-parse --short HEAD 2>/dev/null || true)"

SERVER_ID="$SERVER_ID" \
SERVER_NAME="$SERVER_NAME" \
SERVER_LANGUAGE="$SERVER_LANGUAGE" \
SERVER_RUNTIME="$SERVER_RUNTIME" \
SERVER_SUITE="$SERVER_SUITE" \
SERVER_COMMAND_DISPLAY="$SERVER_COMMAND_DISPLAY" \
FIRST_URL="http://$HOST:$FIRST_PORT/json" \
URLS="$URLS" \
CONNECTION_TARGETS="$CONNECTION_TARGETS" \
MAX_CONNECTIONS="$MAX_CONNECTIONS" \
PAYLOAD_BYTES="$PAYLOAD_BYTES" \
PAYLOAD_SWEEP_BYTES="$PAYLOAD_SWEEP_BYTES" \
PAYLOAD_SWEEP_SECONDS="$PAYLOAD_SWEEP_SECONDS" \
REQUESTS_PER_SECOND="$REQUESTS_PER_SECOND" \
TARGET_CONNECTION_RATE="$TARGET_CONNECTION_RATE" \
CONNECTION_RETRIES="$CONNECTION_RETRIES" \
CONNECTION_RETRY_DELAY="$CONNECTION_RETRY_DELAY" \
BASELINE_SECONDS="$BASELINE_SECONDS" \
SETTLE_SECONDS="$SETTLE_SECONDS" \
STABILIZE_SECONDS="$STABILIZE_SECONDS" \
TRAFFIC_SECONDS="$TRAFFIC_SECONDS" \
COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
STARTED_AT="$started_at" \
GIT_COMMIT="$git_commit" \
node <<'NODE' > "$RUN_WORK_DIR/metadata.json"
const metadata = {
  id: process.env.SERVER_ID,
  server: process.env.SERVER_NAME,
  language: process.env.SERVER_LANGUAGE || null,
  runtime: process.env.SERVER_RUNTIME || null,
  suite: process.env.SERVER_SUITE || 'http-json',
  server_command: process.env.SERVER_COMMAND_DISPLAY,
  url: process.env.FIRST_URL,
  urls: process.env.URLS.split(',').filter(Boolean),
  connections: Number(process.env.MAX_CONNECTIONS),
  connection_targets: process.env.CONNECTION_TARGETS.split(/[\s,]+/).filter(Boolean).map(Number),
  payload_bytes: Number(process.env.PAYLOAD_BYTES),
  payload_sweep_bytes: process.env.PAYLOAD_SWEEP_BYTES.split(/[\s,]+/).filter(Boolean).map(Number),
  payload_sweep_seconds: Number(process.env.PAYLOAD_SWEEP_SECONDS),
  target_requests_per_second: Number(process.env.REQUESTS_PER_SECOND),
  target_messages_per_second: Number(process.env.REQUESTS_PER_SECOND),
  target_connection_rate: Number(process.env.TARGET_CONNECTION_RATE),
  connection_retries: Number(process.env.CONNECTION_RETRIES),
  connection_retry_delay: process.env.CONNECTION_RETRY_DELAY,
  baseline_seconds: Number(process.env.BASELINE_SECONDS),
  settle_seconds: Number(process.env.SETTLE_SECONDS),
  stabilize_seconds: Number(process.env.STABILIZE_SECONDS),
  traffic_seconds: Number(process.env.TRAFFIC_SECONDS),
  cooldown_seconds: Number(process.env.COOLDOWN_SECONDS),
  started_at: process.env.STARTED_AT,
  git_commit: process.env.GIT_COMMIT,
};

process.stdout.write(`${JSON.stringify(metadata, null, 2)}\n`);
NODE

echo "starting $SERVER_NAME server"
(
  cd "$SERVER_DIR"
  HOST="$HOST" \
    PORTS="$SERVER_PORTS" \
    ACTIVITY_METRICS_PATH="$RUN_WORK_DIR/activity_metrics.jsonl" \
    SERVER_EVENTS_PATH="$RUN_WORK_DIR/server_events.jsonl" \
    RUNTIME_METRICS_PATH="$RUN_WORK_DIR/runtime_metrics.jsonl" \
    bash -lc "$SERVER_COMMAND_DISPLAY"
) > "$RUN_WORK_DIR/server.log" 2>&1 &
SERVER_PID="$!"

echo "waiting for health endpoint"
for _ in {1..100}; do
  if curl -fsS "http://$HOST:$FIRST_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! curl -fsS "http://$HOST:$FIRST_PORT/health" >/dev/null 2>&1; then
  echo "server did not become healthy; see $RUN_WORK_DIR/server.log" >&2
  exit 1
fi

echo "starting process collector for pid $SERVER_PID"
go build -o "$COLLECTOR_BIN" "$ROOT_DIR/collector/cmd/collector"
(
  "$COLLECTOR_BIN" --pid "$SERVER_PID" --output "$RUN_WORK_DIR/server_metrics.jsonl" --interval 1s
) > "$RUN_WORK_DIR/collector.log" 2>&1 &
COLLECTOR_PID="$!"

echo "running loadgen: ${BASELINE_SECONDS}s baseline, connection target(s) [$CONNECTION_TARGETS] at ${TARGET_CONNECTION_RATE} conn/s with ${CONNECTION_RETRIES} retries after ${CONNECTION_RETRY_DELAY}, ${SETTLE_SECONDS}s settle, ramping to ${REQUESTS_PER_SECOND} req/s over ${TRAFFIC_SECONDS}s, payload sweep [$PAYLOAD_SWEEP_BYTES] for ${PAYLOAD_SWEEP_SECONDS}s each, ${STABILIZE_SECONDS}s stabilize, ${COOLDOWN_SECONDS}s cooldown"
go build -o "$LOADGEN_BIN" "$ROOT_DIR/loadgen/cmd/loadgen"
LOADGEN_STATUS=0
set +e
(
  "$LOADGEN_BIN" \
    --urls "$URLS" \
    --connection-targets "$CONNECTION_TARGETS" \
    --payload-bytes "$PAYLOAD_BYTES" \
    --payload-sweep-bytes "$PAYLOAD_SWEEP_BYTES" \
    --payload-sweep-seconds "$PAYLOAD_SWEEP_SECONDS" \
    --requests-per-second "$REQUESTS_PER_SECOND" \
    --target-connection-rate "$TARGET_CONNECTION_RATE" \
    --connection-retries "$CONNECTION_RETRIES" \
    --connection-retry-delay "$CONNECTION_RETRY_DELAY" \
    --baseline-seconds "$BASELINE_SECONDS" \
    --settle-seconds "$SETTLE_SECONDS" \
    --stabilize-seconds "$STABILIZE_SECONDS" \
    --traffic-seconds "$TRAFFIC_SECONDS" \
    --cooldown-seconds "$COOLDOWN_SECONDS" \
    --output "$RUN_WORK_DIR"
) > "$RUN_WORK_DIR/loadgen.log" 2>&1
LOADGEN_STATUS=$?
set -e

cleanup
COLLECTOR_PID=""
SERVER_PID=""

rm -rf "$RUN_DIR"
mv "$RUN_WORK_DIR" "$RUN_DIR"

echo "run written to $RUN_DIR"
if (( LOADGEN_STATUS != 0 )); then
  echo "loadgen exited with status $LOADGEN_STATUS; artifacts were preserved" >&2
  exit "$LOADGEN_STATUS"
fi
