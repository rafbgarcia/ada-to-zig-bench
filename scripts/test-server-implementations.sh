#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$ROOT_DIR/.tmp/server-implementation-tests"
LOADGEN_BIN="$TMP_DIR/loadgen"

SERVER_PID=""
SERVER_LOG=""

usage() {
  cat <<'EOF'
Usage: scripts/test-server-implementations.sh [server ...]

Validates HTTP JSON server implementations without provisioning benchmark infrastructure.
When no server names are supplied, all servers with servers/<name>/bench.json are tested.
EOF
}

log() {
  printf '[server-test] %s\n' "$*"
}

fail() {
  printf '[server-test] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_java_21() {
  require_command java
  require_command javac

  local version
  version="$(javac -version 2>&1 | awk '{print $2}')"
  local major="${version%%.*}"
  if [[ "$major" == "1" ]]; then
    major="$(printf '%s' "$version" | cut -d. -f2)"
  fi
  [[ "$major" =~ ^[0-9]+$ ]] || fail "could not parse javac version: $version"
  (( major >= 21 )) || fail "javac 21 or newer is required for Java virtual threads; found javac $version"
}

cleanup_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  SERVER_LOG=""
}

handle_exit() {
  cleanup_server
}
trap handle_exit EXIT

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_command bash
  require_command curl
  require_command go
  require_command node

  cd "$ROOT_DIR"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"

  log "building load generator"
  go build -o "$LOADGEN_BIN" "$ROOT_DIR/loadgen/cmd/loadgen"

  if (( $# > 0 )); then
    SERVERS=("$@")
  else
    mapfile -t SERVERS < <(find servers -mindepth 2 -maxdepth 2 -name bench.json -exec dirname {} \; | xargs -n 1 basename | sort)
  fi

  (( ${#SERVERS[@]} > 0 )) || fail "no servers selected"

  local index=0
  local server
  for server in "${SERVERS[@]}"; do
    run_server_test "$server" "$index"
    index=$((index + 1))
  done

  log "all server implementations passed"
}

run_server_test() {
  local server="$1"
  local index="$2"
  local manifest="servers/$server/bench.json"
  local server_dir="servers/$server"
  local run_dir="$TMP_DIR/$server"
  local base_port=$((18080 + (index * 10)))
  local ports="$base_port,$((base_port + 1))"
  local run_command install_command urls first_port

  [[ -f "$manifest" ]] || fail "unknown server: $server"

  run_command="$(manifest_field "$manifest" run)"
  install_command="$(manifest_field "$manifest" install)"
  [[ -n "$run_command" ]] || fail "$manifest is missing a run command"

  require_toolchains "$manifest"

  mkdir -p "$run_dir"
  log "testing $server"
  if [[ -n "$install_command" ]]; then
    log "installing $server dependencies: $install_command"
    (cd "$server_dir" && bash -c "$install_command")
  fi

  start_server "$server" "$server_dir" "$run_command" "$ports" "$run_dir"
  first_port="${ports%%,*}"
  wait_for_health "$server" "$first_port" "$SERVER_LOG"

  urls="$(json_urls "$ports")"
  node scripts/check-http-json-server.mjs $(base_urls "$ports")

  "$LOADGEN_BIN" \
    --urls "$urls" \
    --client-connections 8 \
    --payload-bytes 128 \
    --payload-sweep-bytes "0 512" \
    --payload-sweep-seconds 1 \
    --requests-per-second 20 \
    --work-mode fixed-work \
    --connection-retries 1 \
    --connection-retry-delay 100ms \
    --output "$run_dir/loadgen" > "$run_dir/loadgen.log" 2>&1

  node - "$run_dir/loadgen/summary.json" "$server" <<'NODE'
const fs = require('node:fs');
const [summaryPath, server] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
if (!summary.success || !summary.complete) throw new Error(`${server}: loadgen did not complete`);
if (summary.total_errors !== 0) throw new Error(`${server}: loadgen reported ${summary.total_errors} error(s)`);
if (summary.total_dispatch_misses !== 0) throw new Error(`${server}: loadgen reported ${summary.total_dispatch_misses} dispatch miss(es)`);
if (summary.total_received !== summary.total_sent) throw new Error(`${server}: received ${summary.total_received} responses for ${summary.total_sent} requests`);
NODE

  cleanup_server
}

start_server() {
  local server="$1"
  local server_dir="$2"
  local run_command="$3"
  local ports="$4"
  local run_dir="$5"

  cleanup_server
  SERVER_LOG="$run_dir/server.log"
  (
    cd "$server_dir"
    HOST=127.0.0.1 \
      PORTS="$ports" \
      ACTIVITY_METRICS_PATH="$run_dir/activity_metrics.jsonl" \
      SERVER_EVENTS_PATH="$run_dir/server_events.jsonl" \
      RUNTIME_METRICS_PATH="$run_dir/runtime_metrics.jsonl" \
      bash -c "$run_command"
  ) > "$SERVER_LOG" 2>&1 &
  SERVER_PID="$!"

  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "$server process did not start; see $SERVER_LOG"
  fi
}

wait_for_health() {
  local server="$1"
  local port="$2"
  local log_path="$3"

  for _ in {1..100}; do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      fail "$server process exited before health check passed; see $log_path"
    fi
    sleep 0.1
  done

  fail "$server did not become healthy on port $port; see $log_path"
}

manifest_field() {
  local manifest="$1"
  local field="$2"
  node scripts/manifest-field.mjs "$manifest" "$field"
}

require_toolchains() {
  local manifest="$1"
  local toolchains toolchain
  toolchains="$(manifest_field "$manifest" toolchains)"
  IFS=',' read -r -a TOOLCHAIN_ARRAY <<<"$toolchains"

  for toolchain in "${TOOLCHAIN_ARRAY[@]}"; do
    toolchain="${toolchain//[[:space:]]/}"
    [[ -n "$toolchain" ]] || continue
    case "$toolchain" in
      ada) require_command gprbuild ;;
      bun) require_command bun ;;
      c) require_command cc ; require_command pkg-config ;;
      cpp) require_command c++ ; require_command pkg-config ;;
      csharp) require_command dotnet ;;
      elixir) require_command elixir ; require_command mix ;;
      erlang) require_command erl ; require_command rebar3 ;;
      go) require_command go ;;
      java) require_java_21 ;;
      node) require_command node ;;
      python) require_command python3 ;;
      ruby) require_command ruby ;;
      rust) require_command cargo ;;
      zig) require_command zig ;;
      *) fail "unknown toolchain '$toolchain' in $manifest" ;;
    esac
  done
}

base_urls() {
  local ports="$1"
  local port
  IFS=',' read -r -a PORT_ARRAY <<<"$ports"
  for port in "${PORT_ARRAY[@]}"; do
    printf 'http://127.0.0.1:%s\n' "$port"
  done
}

json_urls() {
  local ports="$1"
  local urls=()
  local port
  IFS=',' read -r -a PORT_ARRAY <<<"$ports"
  for port in "${PORT_ARRAY[@]}"; do
    urls+=("http://127.0.0.1:$port/json")
  done
  local IFS=,
  printf '%s' "${urls[*]}"
}

main "$@"
