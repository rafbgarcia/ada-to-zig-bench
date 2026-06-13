#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LATITUDE_PROJECT="${LATITUDE_PROJECT:-${LSH_PROJECT:-default-project}}"
LATITUDE_SITE="${LATITUDE_SITE:-ASH}"
LATITUDE_SERVER_PLAN="${LATITUDE_SERVER_PLAN:-m4-metal-small}"
LATITUDE_LOADGEN_PLAN="${LATITUDE_LOADGEN_PLAN:-$LATITUDE_SERVER_PLAN}"
LATITUDE_OPERATING_SYSTEM="${LATITUDE_OPERATING_SYSTEM:-ubuntu_24_04_x64_lts}"
LATITUDE_BILLING="${LATITUDE_BILLING:-hourly}"
LATITUDE_SSH_KEYS="${LATITUDE_SSH_KEYS:-}"
LATITUDE_KEEP_INFRA="${LATITUDE_KEEP_INFRA:-0}"

SERVER_NAME="${SERVER_NAME:-}"
SERVER_NAMES="${SERVER_NAMES:-}"
BENCHMARK_CONNECTIONS="${BENCHMARK_CONNECTIONS:-1000 10000 50000 100000}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-256}"
REQUESTS_PER_SECOND="${REQUESTS_PER_SECOND:-10000}"
TARGET_CONNECTION_RATE="${TARGET_CONNECTION_RATE:-10000}"
BASELINE_SECONDS="${BASELINE_SECONDS:-10}"
SETTLE_SECONDS="${SETTLE_SECONDS:-10}"
TRAFFIC_SECONDS="${TRAFFIC_SECONDS:-120}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-20}"
REMOTE_PORTS="${REMOTE_PORTS:-8080,8081,8082,8083}"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15 -o ServerAliveCountMax=8)

SERVER_ID=""
LOADGEN_ID=""
SERVER_IPV4=""
LOADGEN_IPV4=""

usage() {
  cat <<'EOF'
Usage: scripts/run-latitude-benchmarks.sh [server ...]

Runs missing HTTP JSON benchmark suites on Latitude bare metal and writes each completed suite to:
  servers/<server>/benchmark/

Environment:
  LATITUDESH_TOKEN            required by lsh in CI/non-interactive use
  LATITUDE_PROJECT            default: default-project; can also use LSH_PROJECT
  LATITUDE_SSH_KEYS           comma-separated Latitude SSH key IDs or names
  LATITUDE_SITE               default: ASH
  LATITUDE_SERVER_PLAN        default: m4-metal-small
  LATITUDE_LOADGEN_PLAN       default: LATITUDE_SERVER_PLAN
  LATITUDE_OPERATING_SYSTEM   default: ubuntu_24_04_x64_lts
  LATITUDE_BILLING            default: hourly
  SERVER_NAMES                optional space-separated servers; auto-detected by default
  BENCHMARK_CONNECTIONS       default: "1000 10000 50000 100000"
  PAYLOAD_BYTES               default: 256
  REQUESTS_PER_SECOND         default: 10000
  TARGET_CONNECTION_RATE      default: 10000
  TRAFFIC_SECONDS             default: 120
  LATITUDE_KEEP_INFRA         set to 1 to keep bare metal hosts after the run
EOF
}

log() {
  printf '[latitude-bench] %s\n' "$*"
}

fail() {
  printf '[latitude-bench] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

cleanup() {
  if [[ "$LATITUDE_KEEP_INFRA" == "1" ]]; then
    log "keeping Latitude infrastructure because LATITUDE_KEEP_INFRA=1"
    return
  fi

  set +e
  [[ -n "$LOADGEN_ID" ]] && lsh --no-input servers destroy --id "$LOADGEN_ID" >/dev/null 2>&1
  [[ -n "$SERVER_ID" ]] && lsh --no-input servers destroy --id "$SERVER_ID" >/dev/null 2>&1
}
trap cleanup EXIT

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_command lsh
  require_command ssh
  require_command scp
  require_command tar
  require_command jq
  require_command node

  [[ -n "${LATITUDESH_TOKEN:-}" || -n "${LSH_PROFILE:-}" || -f "${HOME:-}/.config/lsh/config.json" ]] || fail "LATITUDESH_TOKEN is required unless lsh is already authenticated"
  [[ -n "$LATITUDE_SSH_KEYS" ]] || fail "LATITUDE_SSH_KEYS is required"

  cd "$ROOT_DIR"
  export LSH_PROJECT="$LATITUDE_PROJECT"

  if (( $# > 0 )); then
    SERVERS=("$@")
  elif [[ -n "$SERVER_NAME" ]]; then
    read -r -a SERVERS <<<"$SERVER_NAME"
  elif [[ -n "$SERVER_NAMES" ]]; then
    read -r -a SERVERS <<<"$SERVER_NAMES"
  else
    mapfile -t SERVERS < <(find servers -mindepth 2 -maxdepth 2 -name bench.json -exec dirname {} \; | xargs -n 1 basename | sort)
  fi

  read -r -a SCENARIO_CONNECTIONS <<<"$BENCHMARK_CONNECTIONS"
  (( ${#SERVERS[@]} > 0 )) || fail "no servers selected"
  (( ${#SCENARIO_CONNECTIONS[@]} > 0 )) || fail "no benchmark scenarios selected"

  for server in "${SERVERS[@]}"; do
    [[ -f "servers/$server/bench.json" ]] || fail "unknown server: $server"
  done

  MISSING_SERVERS=()
  for server in "${SERVERS[@]}"; do
    if benchmark_complete "$server"; then
      log "servers/$server/benchmark already exists with all scenarios; skipping"
    else
      MISSING_SERVERS+=("$server")
    fi
  done

  if (( ${#MISSING_SERVERS[@]} == 0 )); then
    log "no missing benchmarks"
    exit 0
  fi

  for connections in "${SCENARIO_CONNECTIONS[@]}"; do
    [[ "$connections" =~ ^[0-9]+$ ]] || fail "invalid connection count: $connections"
  done

  log "running missing servers: ${MISSING_SERVERS[*]}"
  log "scenarios: ${SCENARIO_CONNECTIONS[*]} connections; target request rate: ${REQUESTS_PER_SECOND}/s"

  create_infrastructure
  prepare_hosts

  for server in "${MISSING_SERVERS[@]}"; do
    run_server_suite "$server"
  done

  log "completed all missing benchmarks"
}

benchmark_complete() {
  local server="$1"
  local metadata="servers/$server/benchmark/metadata.json"
  local summary="servers/$server/benchmark/summary.json"

  [[ -f "$metadata" && -f "$summary" ]] || return 1

  jq -e --argjson expected "$(scenario_json)" '
    .scenarios as $actual
    | ($actual | type) == "array"
    and (($actual | map(.connections) | sort) == ($expected | sort))
  ' "$summary" >/dev/null 2>&1
}

scenario_json() {
  printf '%s\n' "${SCENARIO_CONNECTIONS[@]}" | jq -cs 'map(tonumber)'
}

create_infrastructure() {
  local suffix
  suffix="$(date -u +%Y%m%d%H%M%S)-$RANDOM"

  log "creating Latitude server host"
  local server_json
  server_json="$(lsh --no-input servers create \
    --project "$LATITUDE_PROJECT" \
    --site "$LATITUDE_SITE" \
    --plan "$LATITUDE_SERVER_PLAN" \
    --operating_system "$LATITUDE_OPERATING_SYSTEM" \
    --hostname "bench-server-$suffix" \
    --billing "$LATITUDE_BILLING" \
    --ssh_keys "$LATITUDE_SSH_KEYS" \
    --json)"
  SERVER_ID="$(printf '%s\n' "$server_json" | latitude_server_id)"

  log "creating Latitude loadgen host"
  local loadgen_json
  loadgen_json="$(lsh --no-input servers create \
    --project "$LATITUDE_PROJECT" \
    --site "$LATITUDE_SITE" \
    --plan "$LATITUDE_LOADGEN_PLAN" \
    --operating_system "$LATITUDE_OPERATING_SYSTEM" \
    --hostname "bench-loadgen-$suffix" \
    --billing "$LATITUDE_BILLING" \
    --ssh_keys "$LATITUDE_SSH_KEYS" \
    --json)"
  LOADGEN_ID="$(printf '%s\n' "$loadgen_json" | latitude_server_id)"

  [[ -n "$SERVER_ID" && "$SERVER_ID" != "null" ]] || fail "could not parse server host ID"
  [[ -n "$LOADGEN_ID" && "$LOADGEN_ID" != "null" ]] || fail "could not parse loadgen host ID"

  SERVER_IPV4="$(wait_for_ipv4 "$SERVER_ID")"
  LOADGEN_IPV4="$(wait_for_ipv4 "$LOADGEN_ID")"

  wait_for_ssh "$SERVER_IPV4"
  wait_for_ssh "$LOADGEN_IPV4"
}

latitude_server_id() {
  jq -r '
    .id // .server.id // .data.id // .data.attributes.id // .attributes.id //
    (if (.data | type) == "array" then .data[0].id else empty end) // empty
  '
}

wait_for_ipv4() {
  local id="$1"
  for _ in {1..240}; do
    local ip
    ip="$(server_public_ipv4 "$id")"
    if [[ -n "$ip" && "$ip" != "null" ]]; then
      printf '%s\n' "$ip"
      return
    fi
    sleep 5
  done
  fail "server $id did not receive a public IPv4"
}

server_public_ipv4() {
  lsh --no-input servers get --id "$1" --json | jq -r '
    def ip_value:
      if type == "string" then .
      elif type == "object" then (.ip // .address // .address_family4 // .value // empty)
      else empty end;

    [
      .primary_ipv4, .public_ipv4, .ip, .ipv4,
      .attributes.primary_ipv4, .attributes.public_ipv4, .attributes.ip, .attributes.ipv4,
      .server.primary_ipv4, .server.public_ipv4, .server.ip, .server.ipv4,
      .server.attributes.primary_ipv4, .server.attributes.public_ipv4, .server.attributes.ip, .server.attributes.ipv4,
      .data.primary_ipv4, .data.public_ipv4, .data.ip, .data.ipv4,
      .data.attributes.primary_ipv4, .data.attributes.public_ipv4, .data.attributes.ip, .data.attributes.ipv4
    ] | map(ip_value) | map(select(. != null and . != "")) | first // empty
  '
}

wait_for_ssh() {
  local ip="$1"
  log "waiting for SSH on $ip"
  for _ in {1..240}; do
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" true >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done
  fail "SSH did not become ready on $ip"
}

prepare_hosts() {
  log "creating source archive"
  local archive
  archive="$(mktemp -t bench-src.XXXXXX.tar.gz)"
  tar \
    --exclude='.git' \
    --exclude='.tmp' \
    --exclude='node_modules' \
    --exclude='web/dist' \
    --exclude='servers/*/benchmark' \
    -czf "$archive" -C "$ROOT_DIR" .

  upload_and_prepare_server "$SERVER_IPV4" "$archive"
  upload_and_prepare_loadgen "$LOADGEN_IPV4" "$archive"

  rm -f "$archive"
}

upload_and_prepare_server() {
  local ip="$1"
  local archive="$2"
  log "preparing server host $ip"
  scp "${SSH_OPTS[@]}" "$archive" "$SSH_USER@$ip:/tmp/bench-src.tar.gz" >/dev/null
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" 'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n 1048576 || true
cat >/etc/security/limits.d/99-bench.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
sysctl -w fs.file-max=2097152 net.core.somaxconn=65535 net.ipv4.ip_local_port_range="1024 65535" net.ipv4.tcp_tw_reuse=1 >/dev/null || true
rm -rf /opt/bench
mkdir -p /opt/bench
tar -xzf /tmp/bench-src.tar.gz -C /opt/bench
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git build-essential jq procps unzip xz-utils
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
curl -fsSL https://bun.sh/install | bash
curl -fsSL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH="/usr/local/go/bin:/root/.bun/bin:$PATH"
export BUN_INSTALL="/root/.bun"
cd /opt/bench
mkdir -p /opt/bench/.tmp
node scripts/prepare-server-dependencies.mjs
go build -o /opt/bench/.tmp/collector ./collector/cmd/collector
REMOTE
}

upload_and_prepare_loadgen() {
  local ip="$1"
  local archive="$2"
  log "preparing loadgen host $ip"
  scp "${SSH_OPTS[@]}" "$archive" "$SSH_USER@$ip:/tmp/bench-src.tar.gz" >/dev/null
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" 'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n 1048576 || true
cat >/etc/security/limits.d/99-bench.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
sysctl -w fs.file-max=2097152 net.core.somaxconn=65535 net.ipv4.ip_local_port_range="1024 65535" net.ipv4.tcp_tw_reuse=1 >/dev/null || true
rm -rf /opt/bench
mkdir -p /opt/bench
tar -xzf /tmp/bench-src.tar.gz -C /opt/bench
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git build-essential jq procps
curl -fsSL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH="/usr/local/go/bin:$PATH"
cd /opt/bench
mkdir -p /opt/bench/.tmp
go build -o /opt/bench/.tmp/loadgen ./loadgen/cmd/loadgen
REMOTE
}

run_server_suite() {
  local server="$1"
  local local_work_dir=".tmp/latitude-$server"
  rm -rf "$local_work_dir"
  mkdir -p "$local_work_dir/scenarios"

  log "running suite for $server"
  remote_server_start "$server" "$local_work_dir"

  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local status=0
  for connections in "${SCENARIO_CONNECTIONS[@]}"; do
    if ! run_scenario "$server" "$connections" "$local_work_dir/scenarios/$connections"; then
      status=1
      break
    fi
  done

  remote_server_stop
  if (( status != 0 )); then
    fail "suite failed for $server"
  fi
  fetch_server_artifacts "$local_work_dir"
  write_suite_metadata "$server" "$started_at" "$local_work_dir"

  rm -rf "servers/$server/benchmark"
  mv "$local_work_dir" "servers/$server/benchmark"
  log "wrote servers/$server/benchmark"
}

remote_server_start() {
  local server="$1"
  local local_work_dir="$2"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IPV4" \
    SERVER_NAME="$server" \
    HOST="0.0.0.0" \
    PORTS="$REMOTE_PORTS" \
    'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n 1048576 || true
export PATH="/usr/local/go/bin:/root/.bun/bin:$PATH"
export BUN_INSTALL="/root/.bun"
cd /opt/bench
manifest="servers/$SERVER_NAME/bench.json"
test -f "$manifest"
run_command="$(node -e "const fs=require('node:fs'); const m=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(m.run || '');" "$manifest")"
test -n "$run_command"
rm -rf .tmp/cloud-server
mkdir -p .tmp/cloud-server
(
  cd "servers/$SERVER_NAME"
  HOST="$HOST" PORTS="$PORTS" \
    RUNTIME_METRICS_PATH="/opt/bench/.tmp/cloud-server/runtime_metrics.jsonl" \
    RUNTIME_EVENTS_PATH="/opt/bench/.tmp/cloud-server/runtime_events.jsonl" \
    bash -lc "$run_command"
) > /opt/bench/.tmp/cloud-server/server.log 2>&1 &
echo "$!" > /opt/bench/.tmp/cloud-server/server.pid
first_port="${PORTS%%,*}"
for _ in {1..300}; do
  if curl -fsS "http://127.0.0.1:$first_port/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$first_port/health" >/dev/null
/opt/bench/.tmp/collector --pid "$(cat /opt/bench/.tmp/cloud-server/server.pid)" --output /opt/bench/.tmp/cloud-server/server_metrics.jsonl --interval 1s > /opt/bench/.tmp/cloud-server/collector.log 2>&1 &
echo "$!" > /opt/bench/.tmp/cloud-server/collector.pid
REMOTE
  printf '{"provider":"latitude.sh","server_public_ip":"%s","loadgen_public_ip":"%s","site":"%s","server_plan":"%s","loadgen_plan":"%s"}\n' \
    "$SERVER_IPV4" "$LOADGEN_IPV4" "$LATITUDE_SITE" "$LATITUDE_SERVER_PLAN" "$LATITUDE_LOADGEN_PLAN" > "$local_work_dir/infrastructure.json"
}

remote_server_stop() {
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IPV4" 'bash -s' <<'REMOTE' || true
set -euo pipefail
if [[ -f /opt/bench/.tmp/cloud-server/collector.pid ]]; then
  kill "$(cat /opt/bench/.tmp/cloud-server/collector.pid)" 2>/dev/null || true
fi
if [[ -f /opt/bench/.tmp/cloud-server/server.pid ]]; then
  kill "$(cat /opt/bench/.tmp/cloud-server/server.pid)" 2>/dev/null || true
fi
REMOTE
}

fetch_server_artifacts() {
  local local_work_dir="$1"
  for file in server_metrics.jsonl runtime_metrics.jsonl runtime_events.jsonl server.log collector.log; do
    scp "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IPV4:/opt/bench/.tmp/cloud-server/$file" "$local_work_dir/$file" >/dev/null || true
  done
}

run_scenario() {
  local server="$1"
  local connections="$2"
  local scenario_dir="$3"
  mkdir -p "$scenario_dir"

  log "$server: running $connections connections from loadgen host"
  run_loadgen "$connections"

  local shard_dir="$scenario_dir/loadgen-0"
  mkdir -p "$shard_dir"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$LOADGEN_IPV4" "tar -C /opt/bench/.tmp/loadgen-$connections -czf - ." | tar -xzf - -C "$shard_dir"
  write_scenario_files "$server" "$connections" "$scenario_dir"
}

run_loadgen() {
  local connections="$1"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$LOADGEN_IPV4" \
    SERVER_PUBLIC_IP="$SERVER_IPV4" \
    CONNECTIONS="$connections" \
    REQUESTS_PER_SECOND="$REQUESTS_PER_SECOND" \
    TARGET_CONNECTION_RATE="$TARGET_CONNECTION_RATE" \
    PAYLOAD_BYTES="$PAYLOAD_BYTES" \
    BASELINE_SECONDS="$BASELINE_SECONDS" \
    SETTLE_SECONDS="$SETTLE_SECONDS" \
    TRAFFIC_SECONDS="$TRAFFIC_SECONDS" \
    COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
    PORTS="$REMOTE_PORTS" \
    'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n 1048576 || true
cd /opt/bench
OUT="/opt/bench/.tmp/loadgen-$CONNECTIONS"
rm -rf "$OUT"
mkdir -p "$OUT"
URLS=""
IFS=',' read -r -a ports <<<"$PORTS"
for port in "${ports[@]}"; do
  port="${port//[[:space:]]/}"
  [[ -n "$port" ]] || continue
  if [[ -n "$URLS" ]]; then URLS+=","; fi
  URLS+="http://$SERVER_PUBLIC_IP:$port/json"
done
/opt/bench/.tmp/loadgen \
  --urls "$URLS" \
  --connections "$CONNECTIONS" \
  --payload-bytes "$PAYLOAD_BYTES" \
  --requests-per-second "$REQUESTS_PER_SECOND" \
  --target-connection-rate "$TARGET_CONNECTION_RATE" \
  --baseline-seconds "$BASELINE_SECONDS" \
  --settle-seconds "$SETTLE_SECONDS" \
  --traffic-seconds "$TRAFFIC_SECONDS" \
  --cooldown-seconds "$COOLDOWN_SECONDS" \
  --output "$OUT" > "$OUT/loadgen.log" 2>&1
REMOTE
}

write_scenario_files() {
  local server="$1"
  local connections="$2"
  local scenario_dir="$3"

  SCENARIO_DIR="$scenario_dir" \
  SERVER_NAME="$server" \
  CONNECTIONS="$connections" \
  PAYLOAD_BYTES="$PAYLOAD_BYTES" \
  REQUESTS_PER_SECOND="$REQUESTS_PER_SECOND" \
  TARGET_CONNECTION_RATE="$TARGET_CONNECTION_RATE" \
  TRAFFIC_SECONDS="$TRAFFIC_SECONDS" \
  node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const scenarioDir = process.env.SCENARIO_DIR;
const connections = Number(process.env.CONNECTIONS);
const shardDirs = fs.readdirSync(scenarioDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && entry.name.startsWith('loadgen-'))
  .map((entry) => path.join(scenarioDir, entry.name))
  .sort();

const summaries = [];
for (const shardDir of shardDirs) {
  const summaryPath = path.join(shardDir, 'summary.json');
  if (fs.existsSync(summaryPath)) {
    summaries.push(JSON.parse(fs.readFileSync(summaryPath, 'utf8')));
  }
}

if (summaries.length === 0) {
  throw new Error(`no loadgen summaries found for ${connections}`);
}

const merged = {
  server: process.env.SERVER_NAME,
  connections,
  payload_bytes: Number(process.env.PAYLOAD_BYTES),
  target_requests_per_second: summaries.reduce((sum, item) => sum + Number(item.target_requests_per_second || item.target_messages_per_second || 0), 0),
  target_messages_per_second: summaries.reduce((sum, item) => sum + Number(item.target_requests_per_second || item.target_messages_per_second || 0), 0),
  target_connection_rate: Number(process.env.TARGET_CONNECTION_RATE),
  traffic_seconds: Number(process.env.TRAFFIC_SECONDS),
  shard_count: summaries.length,
  total_sent: summaries.reduce((sum, item) => sum + Number(item.total_sent || 0), 0),
  total_received: summaries.reduce((sum, item) => sum + Number(item.total_received || 0), 0),
  total_errors: summaries.reduce((sum, item) => sum + Number(item.total_errors || 0), 0),
  peak_active_connections: summaries.reduce((sum, item) => sum + Number(item.peak_active_connections || 0), 0),
  started_at: summaries.map((item) => item.started_at).filter(Boolean).sort()[0] || null,
  finished_at: summaries.map((item) => item.finished_at).filter(Boolean).sort().at(-1) || null,
  p50_latency_ms: percentileFromSummaries(summaries, 'p50_latency_ms'),
  p90_latency_ms: percentileFromSummaries(summaries, 'p90_latency_ms'),
  p99_latency_ms: percentileFromSummaries(summaries, 'p99_latency_ms'),
  max_latency_ms: Math.max(...summaries.map((item) => Number(item.max_latency_ms || 0))),
  shards: summaries,
};

fs.writeFileSync(path.join(scenarioDir, 'summary.json'), `${JSON.stringify(merged, null, 2)}\n`);
writeJSONL(path.join(scenarioDir, 'loadgen_metrics.jsonl'), aggregateLoadgenMetrics(shardDirs));

function percentileFromSummaries(items, key) {
  const weighted = items
    .map((item) => ({ value: Number(item[key] || 0), weight: Math.max(1, Number(item.total_received || 0)) }))
    .sort((a, b) => a.value - b.value);
  const total = weighted.reduce((sum, item) => sum + item.weight, 0);
  let seen = 0;
  for (const item of weighted) {
    seen += item.weight;
    if (seen >= total / 2) return item.value;
  }
  return weighted.at(-1)?.value || 0;
}

function aggregateLoadgenMetrics(shardDirs) {
  const bySecond = new Map();

  for (const shardDir of shardDirs) {
    const metricsPath = path.join(shardDir, 'loadgen_metrics.jsonl');
    if (!fs.existsSync(metricsPath)) continue;

    for (const sample of readJSONL(metricsPath)) {
      const second = Number(sample.elapsed_seconds || 0);
      const existing = bySecond.get(second) ?? {
        ts: sample.ts,
        elapsed_seconds: second,
        phase: sample.phase ?? 'unknown',
        active_connections: 0,
        sent: 0,
        received: 0,
        errors: 0,
        sent_per_second: 0,
        received_per_second: 0,
        errors_per_second: 0,
        p50_weighted_sum: 0,
        p90_weighted_sum: 0,
        p99_weighted_sum: 0,
        latency_weight: 0,
        max_latency_ms: 0,
      };

      if (String(sample.ts || '').localeCompare(String(existing.ts || '')) < 0) existing.ts = sample.ts;
      existing.active_connections += Number(sample.active_connections || 0);
      existing.sent += Number(sample.sent || 0);
      existing.received += Number(sample.received || 0);
      existing.errors += Number(sample.errors || 0);
      existing.sent_per_second += Number(sample.sent_per_second || 0);
      existing.received_per_second += Number(sample.received_per_second || 0);
      existing.errors_per_second += Number(sample.errors_per_second || 0);

      const weight = Math.max(1, Number(sample.received_per_second || 0));
      existing.p50_weighted_sum += Number(sample.p50_latency_ms || 0) * weight;
      existing.p90_weighted_sum += Number(sample.p90_latency_ms || 0) * weight;
      existing.p99_weighted_sum += Number(sample.p99_latency_ms || 0) * weight;
      existing.latency_weight += weight;
      existing.max_latency_ms = Math.max(existing.max_latency_ms, Number(sample.max_latency_ms || 0));
      bySecond.set(second, existing);
    }
  }

  return [...bySecond.values()]
    .sort((a, b) => a.elapsed_seconds - b.elapsed_seconds)
    .map((sample) => ({
      ts: sample.ts,
      elapsed_seconds: sample.elapsed_seconds,
      phase: sample.phase,
      active_connections: sample.active_connections,
      sent: sample.sent,
      received: sample.received,
      errors: sample.errors,
      sent_per_second: sample.sent_per_second,
      received_per_second: sample.received_per_second,
      errors_per_second: sample.errors_per_second,
      p50_latency_ms: sample.latency_weight ? sample.p50_weighted_sum / sample.latency_weight : 0,
      p90_latency_ms: sample.latency_weight ? sample.p90_weighted_sum / sample.latency_weight : 0,
      p99_latency_ms: sample.latency_weight ? sample.p99_weighted_sum / sample.latency_weight : 0,
      max_latency_ms: sample.max_latency_ms,
    }));
}

function readJSONL(filePath) {
  return fs.readFileSync(filePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function writeJSONL(filePath, rows) {
  fs.writeFileSync(filePath, rows.map((row) => JSON.stringify(row)).join('\n') + (rows.length ? '\n' : ''));
}
NODE
}

write_suite_metadata() {
  local server="$1"
  local started_at="$2"
  local local_work_dir="$3"

  SUITE_DIR="$local_work_dir" \
  SERVER_NAME="$server" \
  STARTED_AT="$started_at" \
  GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)" \
  SERVER_PUBLIC_IP="$SERVER_IPV4" \
  LOADGEN_PUBLIC_IP="$LOADGEN_IPV4" \
  LATITUDE_SITE="$LATITUDE_SITE" \
  LATITUDE_SERVER_PLAN="$LATITUDE_SERVER_PLAN" \
  LATITUDE_LOADGEN_PLAN="$LATITUDE_LOADGEN_PLAN" \
  REMOTE_PORTS="$REMOTE_PORTS" \
  SCENARIOS="${SCENARIO_CONNECTIONS[*]}" \
  node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const suiteDir = process.env.SUITE_DIR;
const serverName = process.env.SERVER_NAME;
const manifest = JSON.parse(fs.readFileSync(path.join('servers', serverName, 'bench.json'), 'utf8'));
const scenarioConnections = process.env.SCENARIOS.split(/\s+/).filter(Boolean).map(Number);
const scenarios = scenarioConnections.map((connections) => {
  const scenarioDir = path.join(suiteDir, 'scenarios', String(connections));
  const summary = JSON.parse(fs.readFileSync(path.join(scenarioDir, 'summary.json'), 'utf8'));
  return {
    connections,
    path: `scenarios/${connections}`,
    ...summary,
  };
});

const ports = process.env.REMOTE_PORTS.split(',').map((port) => port.trim()).filter(Boolean);
const urls = ports.map((port) => `http://${process.env.SERVER_PUBLIC_IP}:${port}/json`);
const metadata = {
  id: manifest.id || serverName,
  server: serverName,
  language: manifest.language ?? null,
  runtime: manifest.runtime ?? null,
  suite: manifest.suite || 'http-json',
  server_command: manifest.run || '',
  url: urls[0],
  urls,
  connections: Math.max(...scenarioConnections),
  scenarios: scenarioConnections,
  payload_bytes: scenarios[0]?.payload_bytes ?? null,
  target_requests_per_second: Math.max(...scenarios.map((item) => item.target_requests_per_second || item.target_messages_per_second || 0)),
  target_messages_per_second: Math.max(...scenarios.map((item) => item.target_requests_per_second || item.target_messages_per_second || 0)),
  target_connection_rate: Math.max(...scenarios.map((item) => item.target_connection_rate || 0)),
  baseline_seconds: scenarios[0]?.shards?.[0]?.baseline_seconds ?? null,
  settle_seconds: scenarios[0]?.shards?.[0]?.settle_seconds ?? null,
  traffic_seconds: scenarios[0]?.traffic_seconds ?? null,
  cooldown_seconds: scenarios[0]?.shards?.[0]?.cooldown_seconds ?? null,
  started_at: process.env.STARTED_AT,
  git_commit: process.env.GIT_COMMIT,
  benchmark_recommendations: {
    topology: 'dedicated Latitude server host plus dedicated Latitude loadgen host in the same site',
    request_shape: 'HTTP/1.1 keep-alive POST /json with JSON parse, validation, checksum, and JSON response serialization',
    primary_metrics: ['rss_mb', 'cpu_percent', 'threads', 'open_fds'],
    notes: [
      'Load generation is isolated from the measured server host.',
      'Connections are distributed over multiple server ports to avoid client ephemeral-port exhaustion at 100k connections.',
      'A fixed request rate keeps connection-count scenarios comparable; latency remains a backpressure signal.',
    ],
  },
  infrastructure: {
    provider: 'latitude.sh',
    site: process.env.LATITUDE_SITE,
    server_plan: process.env.LATITUDE_SERVER_PLAN,
    loadgen_plan: process.env.LATITUDE_LOADGEN_PLAN,
    server_public_ip: process.env.SERVER_PUBLIC_IP,
    loadgen_public_ip: process.env.LOADGEN_PUBLIC_IP,
  },
};

const summary = {
  server: serverName,
  suite: metadata.suite,
  started_at: process.env.STARTED_AT,
  finished_at: scenarios.map((item) => item.finished_at).filter(Boolean).sort().at(-1) || null,
  scenarios,
};

writeScenarioServerFiles(suiteDir, scenarios);

fs.writeFileSync(path.join(suiteDir, 'metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
fs.writeFileSync(path.join(suiteDir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);

function writeScenarioServerFiles(suiteDir, scenarios) {
  const serverMetrics = readJSONL(path.join(suiteDir, 'server_metrics.jsonl'));
  const runtimeMetrics = readJSONL(path.join(suiteDir, 'runtime_metrics.jsonl'));
  const runtimeEvents = readJSONL(path.join(suiteDir, 'runtime_events.jsonl'));

  for (const scenario of scenarios) {
    const scenarioDir = path.join(suiteDir, scenario.path);
    const start = Date.parse(scenario.started_at);
    const end = Date.parse(scenario.finished_at);
    const inWindow = (sample) => {
      const ts = Date.parse(sample.ts);
      return Number.isFinite(ts) && Number.isFinite(start) && Number.isFinite(end) && ts >= start - 1000 && ts <= end + 1000;
    };

    writeJSONL(path.join(scenarioDir, 'server_metrics.jsonl'), serverMetrics.filter(inWindow));
    writeJSONL(path.join(scenarioDir, 'runtime_metrics.jsonl'), runtimeMetrics.filter(inWindow));
    writeJSONL(path.join(scenarioDir, 'runtime_events.jsonl'), runtimeEvents.filter(inWindow));
  }
}

function readJSONL(filePath) {
  if (!fs.existsSync(filePath)) return [];
  return fs.readFileSync(filePath, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function writeJSONL(filePath, rows) {
  fs.writeFileSync(filePath, rows.map((row) => JSON.stringify(row)).join('\n') + (rows.length ? '\n' : ''));
}
NODE
}

main "$@"
