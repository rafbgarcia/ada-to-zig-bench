#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

LATITUDE_PROJECT="${LATITUDE_PROJECT:-${LSH_PROJECT:-default-project}}"
LATITUDE_SITE="${LATITUDE_SITE:-ASH}"
LATITUDE_SERVER_PLAN="${LATITUDE_SERVER_PLAN:-f4-metal-small}"
LATITUDE_LOADGEN_PLAN="${LATITUDE_LOADGEN_PLAN:-$LATITUDE_SERVER_PLAN}"
LATITUDE_OPERATING_SYSTEM="${LATITUDE_OPERATING_SYSTEM:-ubuntu_24_04_x64_lts}"
LATITUDE_BILLING="${LATITUDE_BILLING:-hourly}"
LATITUDE_SSH_KEYS="${LATITUDE_SSH_KEYS:-}"
LATITUDE_KEEP_INFRA="${LATITUDE_KEEP_INFRA:-0}"
LATITUDE_PROVISION_ATTEMPTS="${LATITUDE_PROVISION_ATTEMPTS:-2}"
SSH_READY_TIMEOUT_SECONDS="${SSH_READY_TIMEOUT_SECONDS:-600}"
SSH_CONNECT_TIMEOUT_SECONDS="${SSH_CONNECT_TIMEOUT_SECONDS:-5}"

SERVER_NAME="${SERVER_NAME:-}"
SERVER_NAMES="${SERVER_NAMES:-}"
BENCHMARK_CONNECTIONS="${BENCHMARK_CONNECTIONS:-1000000}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-256}"
PAYLOAD_SWEEP_BYTES="${PAYLOAD_SWEEP_BYTES:-256 1024 4096 16384}"
PAYLOAD_SWEEP_SECONDS="${PAYLOAD_SWEEP_SECONDS:-5}"
REQUESTS_PER_SECOND="${REQUESTS_PER_SECOND:-100000}"
TARGET_CONNECTION_RATE="${TARGET_CONNECTION_RATE:-50000}"
CONNECTION_RETRIES="${CONNECTION_RETRIES:-3}"
CONNECTION_RETRY_DELAY="${CONNECTION_RETRY_DELAY:-1s}"
BASELINE_SECONDS="${BASELINE_SECONDS:-0}"
SETTLE_SECONDS="${SETTLE_SECONDS:-0}"
STABILIZE_SECONDS="${STABILIZE_SECONDS:-0}"
TRAFFIC_SECONDS="${TRAFFIC_SECONDS:-10}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"
DEFAULT_REMOTE_PORTS="$(port_range_csv 8080 32)"
REMOTE_PORTS="${REMOTE_PORTS:-$DEFAULT_REMOTE_PORTS}"
SSH_USER="${SSH_USER:-}"
if [[ -z "$SSH_USER" ]]; then
  case "$LATITUDE_OPERATING_SYSTEM" in
    ubuntu*) SSH_USER="ubuntu" ;;
    debian*) SSH_USER="debian" ;;
    rocky*) SSH_USER="rocky" ;;
    centos*) SSH_USER="centos" ;;
    *) SSH_USER="root" ;;
  esac
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15 -o ServerAliveCountMax=8)

SERVER_ID=""
LOADGEN_ID=""
SERVER_IPV4=""
LOADGEN_IPV4=""
SERVER_HOSTNAME=""
LOADGEN_HOSTNAME=""

usage() {
  cat <<'EOF'
Usage: scripts/run-latitude-benchmarks.sh [--list-missing] [server ...]

Runs missing HTTP JSON benchmark suites on Latitude bare metal and writes each completed suite to:
  servers/<server>/benchmark/

Options:
  --list-missing             print servers missing complete benchmark artifacts and exit

Environment:
  LATITUDESH_TOKEN            required by lsh in CI/non-interactive use
  LATITUDE_PROJECT            default: default-project; can also use LSH_PROJECT
  LATITUDE_SSH_KEYS           comma-separated Latitude SSH key IDs or names
  LATITUDE_SITE               default: ASH
  LATITUDE_SERVER_PLAN        default: f4-metal-small
  LATITUDE_LOADGEN_PLAN       default: LATITUDE_SERVER_PLAN
  LATITUDE_OPERATING_SYSTEM   default: ubuntu_24_04_x64_lts
  LATITUDE_BILLING            default: hourly
  LATITUDE_PROVISION_ATTEMPTS default: 2
  SSH_USER                    default: distro user inferred from LATITUDE_OPERATING_SYSTEM
  SSH_READY_TIMEOUT_SECONDS   default: 600
  SSH_CONNECT_TIMEOUT_SECONDS default: 5
  SERVER_NAMES                optional space-separated servers; auto-detected by default
  BENCHMARK_CONNECTIONS       default: "1000000" connection target
  PAYLOAD_BYTES               default: 256
  PAYLOAD_SWEEP_BYTES         default: "256 1024 4096 16384" post-ramp payload sizes
  PAYLOAD_SWEEP_SECONDS       default: 5 per post-ramp payload size
  REQUESTS_PER_SECOND         default: 100000 final request rate
  TARGET_CONNECTION_RATE      default: 50000
  CONNECTION_RETRIES          default: 3 failed connection dial/warmup retries
  CONNECTION_RETRY_DELAY      default: 1s between connection retries
  REMOTE_PORTS                default: 8080..8111 target ports for client ephemeral-port fanout
  TRAFFIC_SECONDS             default: 10 request-rate ramp seconds
  STABILIZE_SECONDS           default: 0 after traffic
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

  destroy_infrastructure
}

destroy_infrastructure() {
  set +e
  [[ -n "$LOADGEN_ID" ]] && lsh --no-input servers destroy --id "$LOADGEN_ID" >/dev/null 2>&1
  [[ -n "$SERVER_ID" ]] && lsh --no-input servers destroy --id "$SERVER_ID" >/dev/null 2>&1
  [[ -z "$LOADGEN_ID" && -n "$LOADGEN_HOSTNAME" ]] && destroy_latitude_server_by_hostname "$LOADGEN_HOSTNAME"
  [[ -z "$SERVER_ID" && -n "$SERVER_HOSTNAME" ]] && destroy_latitude_server_by_hostname "$SERVER_HOSTNAME"
  SERVER_ID=""
  LOADGEN_ID=""
  SERVER_IPV4=""
  LOADGEN_IPV4=""
  SERVER_HOSTNAME=""
  LOADGEN_HOSTNAME=""
  set -e
}

handle_interrupt() {
  log "received interrupt; cleaning up Latitude infrastructure"
  cleanup
  trap - EXIT INT TERM
  exit 130
}

handle_termination() {
  log "received termination; cleaning up Latitude infrastructure"
  cleanup
  trap - EXIT INT TERM
  exit 143
}

trap cleanup EXIT
trap handle_interrupt INT
trap handle_termination TERM

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  local list_missing_only=0
  if [[ "${1:-}" == "--list-missing" ]]; then
    list_missing_only=1
    shift
  fi

  require_command jq

  cd "$ROOT_DIR"

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

  for connections in "${SCENARIO_CONNECTIONS[@]}"; do
    [[ "$connections" =~ ^[0-9]+$ ]] || fail "invalid connection count: $connections"
  done

  MISSING_SERVERS=()
  for server in "${SERVERS[@]}"; do
    if benchmark_complete "$server"; then
      if (( list_missing_only == 0 )); then
        log "servers/$server/benchmark already exists with all scenarios; skipping"
      fi
    else
      MISSING_SERVERS+=("$server")
    fi
  done

  if (( list_missing_only == 1 )); then
    if (( ${#MISSING_SERVERS[@]} > 0 )); then
      printf '%s\n' "${MISSING_SERVERS[@]}"
    fi
    exit 0
  fi

  require_command lsh
  require_command ssh
  require_command scp
  require_command tar
  require_command node

  [[ -n "${LATITUDESH_TOKEN:-}" || -n "${LSH_PROFILE:-}" || -f "${HOME:-}/.config/lsh/config.json" ]] || fail "LATITUDESH_TOKEN is required unless lsh is already authenticated"
  [[ -n "$LATITUDE_SSH_KEYS" ]] || fail "LATITUDE_SSH_KEYS is required"

  export LSH_PROJECT="$LATITUDE_PROJECT"

  if (( ${#MISSING_SERVERS[@]} == 0 )); then
    log "no missing benchmarks"
    exit 0
  fi

  normalize_remote_ports
  validate_remote_port_fanout
  [[ "$LATITUDE_PROVISION_ATTEMPTS" =~ ^[0-9]+$ ]] || fail "invalid Latitude provision attempt count: $LATITUDE_PROVISION_ATTEMPTS"
  (( LATITUDE_PROVISION_ATTEMPTS > 0 )) || fail "LATITUDE_PROVISION_ATTEMPTS must be greater than zero"
  [[ "$SSH_READY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail "invalid SSH readiness timeout: $SSH_READY_TIMEOUT_SECONDS"
  (( SSH_READY_TIMEOUT_SECONDS > 0 )) || fail "SSH_READY_TIMEOUT_SECONDS must be greater than zero"
  [[ "$SSH_CONNECT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail "invalid SSH connect timeout: $SSH_CONNECT_TIMEOUT_SECONDS"
  (( SSH_CONNECT_TIMEOUT_SECONDS > 0 )) || fail "SSH_CONNECT_TIMEOUT_SECONDS must be greater than zero"

  log "running missing servers: ${MISSING_SERVERS[*]}"
  log "connection target(s): ${SCENARIO_CONNECTIONS[*]}; final request rate: ${REQUESTS_PER_SECOND}/s"
  log "payload sweep: [$PAYLOAD_SWEEP_BYTES] for ${PAYLOAD_SWEEP_SECONDS}s each after request-rate ramp"
  log "server target ports: $REMOTE_PORTS"

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

  jq -e \
    --argjson expected "$(scenario_json)" \
    --argjson expectedPayloadBytes "$PAYLOAD_BYTES" \
    --argjson expectedTargetRPS "$REQUESTS_PER_SECOND" \
    --argjson expectedSweep "$(payload_sweep_json)" \
    --argjson expectedSweepSeconds "$PAYLOAD_SWEEP_SECONDS" '
    (.connection_targets // .scenarios // []) as $actual
    | (($expected | max) // 0) as $maxExpected
    | ($actual | type) == "array"
    and (($actual | map(if type == "object" then .target_connections // .connections else . end) | sort) == ($expected | sort))
    and ((.payload_bytes // -1) == $expectedPayloadBytes)
    and ((.target_requests_per_second // .target_messages_per_second // -1) == $expectedTargetRPS)
    and (((.payload_sweep_bytes // []) | sort) == ($expectedSweep | sort))
    and ((.payload_sweep_seconds // 0) == $expectedSweepSeconds)
    and (((.complete // false) == true) or ((.success // false) == true) or ((.peak_active_connections // 0) >= $maxExpected))
  ' "$summary" >/dev/null 2>&1
}

scenario_json() {
  printf '%s\n' "${SCENARIO_CONNECTIONS[@]}" | jq -cs 'map(tonumber)'
}

payload_sweep_json() {
  printf '%s\n' "$PAYLOAD_SWEEP_BYTES" | tr ', ' '\n' | awk 'NF' | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)'
}

payload_sweep_csv() {
  printf '%s\n' "$PAYLOAD_SWEEP_BYTES" | tr ', ' '\n' | awk 'NF' | paste -sd, -
}

connection_targets_csv() {
  local IFS=,
  printf '%s' "${SCENARIO_CONNECTIONS[*]}"
}

normalize_remote_ports() {
  local port raw_ports normalized_ports seen

  IFS=',' read -r -a raw_ports <<<"$REMOTE_PORTS"
  normalized_ports=()
  for port in "${raw_ports[@]}"; do
    port="${port//[[:space:]]/}"
    [[ -n "$port" ]] || continue
    [[ "$port" =~ ^[0-9]+$ ]] || fail "invalid REMOTE_PORTS entry: $port"
    (( port > 0 && port < 65536 )) || fail "REMOTE_PORTS entry out of range: $port"
    seen=0
    for existing in "${normalized_ports[@]}"; do
      if [[ "$existing" == "$port" ]]; then
        seen=1
        break
      fi
    done
    (( seen == 1 )) && continue
    normalized_ports+=("$port")
  done

  (( ${#normalized_ports[@]} > 0 )) || fail "REMOTE_PORTS must contain at least one port"
  local IFS=,
  REMOTE_PORTS="${normalized_ports[*]}"
}

validate_remote_port_fanout() {
  local raw_ports max_connections remote_port_count recommended_capacity

  IFS=',' read -r -a raw_ports <<<"$REMOTE_PORTS"
  remote_port_count="${#raw_ports[@]}"
  max_connections="${SCENARIO_CONNECTIONS[$((${#SCENARIO_CONNECTIONS[@]} - 1))]}"
  recommended_capacity=$((remote_port_count * 32000))

  if (( max_connections > recommended_capacity )); then
    fail "REMOTE_PORTS has $remote_port_count port(s), which is too little fanout for $max_connections back-to-back connections from one loadgen IPv4; add target ports or loadgen source IPs"
  fi
}

required_nofile() {
  local max_connections minimum
  max_connections="${SCENARIO_CONNECTIONS[$((${#SCENARIO_CONNECTIONS[@]} - 1))]}"
  minimum=2097152
  if (( max_connections + 65536 > minimum )); then
    printf '%s\n' "$((max_connections + 65536))"
  else
    printf '%s\n' "$minimum"
  fi
}

create_infrastructure() {
  local attempt suffix ssh_ready

  for (( attempt = 1; attempt <= LATITUDE_PROVISION_ATTEMPTS; attempt++ )); do
    suffix="$(date -u +%Y%m%d%H%M%S)-$RANDOM"
    SERVER_HOSTNAME="bench-server-$suffix"
    LOADGEN_HOSTNAME="bench-loadgen-$suffix"

    log "creating Latitude server host (attempt $attempt/$LATITUDE_PROVISION_ATTEMPTS)"
    SERVER_ID="$(create_latitude_server "$SERVER_HOSTNAME" "$LATITUDE_SERVER_PLAN")"

    log "creating Latitude loadgen host (attempt $attempt/$LATITUDE_PROVISION_ATTEMPTS)"
    LOADGEN_ID="$(create_latitude_server "$LOADGEN_HOSTNAME" "$LATITUDE_LOADGEN_PLAN")"

    SERVER_IPV4="$(wait_for_ipv4 "$SERVER_ID")"
    LOADGEN_IPV4="$(wait_for_ipv4 "$LOADGEN_ID")"
    log "Latitude server host $SERVER_ID has public IPv4 $SERVER_IPV4; $(server_summary "$SERVER_ID")"
    log "Latitude loadgen host $LOADGEN_ID has public IPv4 $LOADGEN_IPV4; $(server_summary "$LOADGEN_ID")"

    ssh_ready=1
    if ! wait_for_ssh "$SERVER_IPV4" "server"; then
      log "SSH did not become ready on Latitude server host $SERVER_IPV4"
      ssh_ready=0
    elif ! wait_for_ssh "$LOADGEN_IPV4" "loadgen"; then
      log "SSH did not become ready on Latitude loadgen host $LOADGEN_IPV4"
      ssh_ready=0
    fi

    if (( ssh_ready == 1 )); then
      return
    fi

    if (( attempt < LATITUDE_PROVISION_ATTEMPTS )); then
      log "destroying non-SSH-ready Latitude hosts before retry"
      destroy_infrastructure
      sleep 30
    fi
  done

  fail "Latitude hosts did not become SSH-ready after $LATITUDE_PROVISION_ATTEMPTS attempt(s)"
}

create_latitude_server() {
  local hostname="$1"
  local plan="$2"
  local output json id parse_status
  id=""

  output="$(lsh_output lsh --no-input servers create \
    --project "$LATITUDE_PROJECT" \
    --site "$LATITUDE_SITE" \
    --plan "$plan" \
    --operating_system "$LATITUDE_OPERATING_SYSTEM" \
    --hostname "$hostname" \
    --billing "$LATITUDE_BILLING" \
    --ssh_keys "$LATITUDE_SSH_KEYS" \
    --json)"

  set +e
  json="$(printf '%s' "$output" | extract_first_resource_json)"
  parse_status=$?
  set -e

  if (( parse_status == 0 )); then
    id="$(printf '%s\n' "$json" | latitude_server_id 2>/dev/null || true)"
  fi
  if [[ -z "$id" || "$id" == "null" ]]; then
    id="$(wait_for_server_id_by_hostname "$hostname")"
  fi

  [[ -n "$id" && "$id" != "null" ]] || fail "could not resolve Latitude host ID for $hostname after create output: $(summarize_lsh_output "$output")"
  printf '%s\n' "$id"
}

lsh_output() {
  local output status

  set +e
  output="$($@ 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    fail "lsh command failed with status $status: $(summarize_lsh_output "$output")"
  fi

  printf '%s\n' "$output"
}

lsh_json() {
  local output json parse_status

  output="$(lsh_output "$@")"

  set +e
  json="$(printf '%s' "$output" | extract_first_resource_json)"
  parse_status=$?
  set -e

  if (( parse_status != 0 )); then
    fail "lsh command returned no resource JSON: $(summarize_lsh_output "$output")"
  fi

  printf '%s\n' "$json"
}

extract_first_resource_json() {
  node -e '
const fs = require("node:fs");

const input = fs.readFileSync(0, "utf8");
const candidates = [];
const trimmed = stripAnsi(input).trim();

addCandidate(trimmed);

const closing = { "{": "}", "[": "]" };

for (let start = 0; start < trimmed.length; start += 1) {
  const first = trimmed[start];
  if (first !== "{" && first !== "[") continue;

  const stack = [];
  let inString = false;
  let escaped = false;

  for (let index = start; index < trimmed.length; index += 1) {
    const char = trimmed[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }

    if (char === "\"") {
      inString = true;
      continue;
    }

    if (char === "{" || char === "[") {
      stack.push(closing[char]);
    } else if (char === "}" || char === "]") {
      if (stack.length === 0 || stack[stack.length - 1] !== char) break;
      stack.pop();
      if (stack.length === 0) {
        addCandidate(trimmed.slice(start, index + 1));
        break;
      }
    }
  }
}

for (const candidate of candidates) {
  if (isResourcePayload(candidate)) {
    process.stdout.write(`${JSON.stringify(candidate, null, 2)}\n`);
    process.exit(0);
  }
}

process.exit(1);

function addCandidate(text) {
  if (!text) return;
  try {
    candidates.push(JSON.parse(text));
  } catch {}
}

function stripAnsi(text) {
  return text
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g, "");
}

function isResourcePayload(value) {
  if (Array.isArray(value)) {
    return value.some((item) => item && typeof item === "object" && !Array.isArray(item));
  }
  if (!value || typeof value !== "object") return false;
  if (typeof value.id === "string") return true;
  if (value.data) return isResourcePayload(value.data);
  if (value.server) return isResourcePayload(value.server);
  return Object.keys(value).length > 0;
}
'
}

summarize_lsh_output() {
  local summary
  summary="$(printf '%s' "$1" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/[A-Za-z0-9_=-]{48,}/[redacted]/g' | cut -c 1-240)"
  if [[ -n "$summary" ]]; then
    printf '%s\n' "$summary"
  else
    printf 'empty output\n'
  fi
}

destroy_latitude_server_by_hostname() {
  local hostname="$1"
  local list_json id

  list_json="$(lsh_json lsh --no-input servers list --project "$LATITUDE_PROJECT" --hostname "$hostname" --json 2>/dev/null || true)"
  [[ -n "$list_json" ]] || return
  id="$(printf '%s\n' "$list_json" | latitude_server_id 2>/dev/null || true)"
  [[ -n "$id" && "$id" != "null" ]] || return
  lsh --no-input servers destroy --id "$id" >/dev/null 2>&1 || true
}

wait_for_server_id_by_hostname() {
  local hostname="$1"
  local list_json id

  for _ in {1..30}; do
    list_json="$(lsh_json lsh --no-input servers list --project "$LATITUDE_PROJECT" --hostname "$hostname" --json 2>/dev/null || true)"
    if [[ -n "$list_json" ]]; then
      id="$(printf '%s\n' "$list_json" | latitude_server_id 2>/dev/null || true)"
      if [[ -n "$id" && "$id" != "null" ]]; then
        printf '%s\n' "$id"
        return
      fi
    fi
    sleep 2
  done
}

latitude_server_id() {
  jq -r '
    def roots:
      if type == "array" then .[] else . end;

    def items:
      if type == "array" then .[]
      elif type == "object" then .
      else empty end;

    [
      roots as $root
      | ($root, $root.server?, $root.data?, $root.attributes?)
      | items
      | objects
      | (.id? // .attributes?.id? // empty)
    ]
    | map(select(. != null and . != ""))
    | first // empty
  '
}

latitude_json_shape() {
  jq -r '
    if type == "array" then
      "array length=\(length) first=\(.[0] | if type == "object" then "object keys=" + (keys_unsorted | join(",")) else type end)"
    elif type == "object" then
      "object keys=" + (keys_unsorted | join(","))
    else
      type
    end
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
    def roots:
      if type == "array" then .[] else . end;

    def items:
      if type == "array" then .[]
      elif type == "object" then .
      else empty end;

    def ip_value:
      if type == "string" then .
      elif type == "object" then (.ip? // .address? // .address_family4? // .value? // empty)
      else empty end;

    [
      roots as $root
      | ($root, $root.server?, $root.data?, $root.attributes?)
      | items
      | objects
      | (
          .primary_ipv4?, .public_ipv4?, .ip?, .ipv4?,
          .attributes?.primary_ipv4?, .attributes?.public_ipv4?, .attributes?.ip?, .attributes?.ipv4?
        )
      | ip_value
    ]
    | map(select(. != null and . != ""))
    | first // empty
  '
}

server_summary() {
  local id="$1"
  local output

  output="$(lsh --no-input servers get --id "$id" --json 2>/dev/null | jq -r '
    def roots:
      if type == "array" then .[] else . end;

    def items:
      if type == "array" then .[]
      elif type == "object" then .
      else empty end;

    def ip_value:
      if type == "string" then .
      elif type == "object" then (.ip? // .address? // .address_family4? // .value? // empty)
      else empty end;

    [
      roots as $root
      | ($root, $root.server?, $root.data?, $root.attributes?)
      | items
      | objects
      | {
          hostname: (.hostname? // .attributes?.hostname? // empty),
          status: (.status? // .attributes?.status? // .state? // .attributes?.state? // empty),
          ip: ((.primary_ipv4?, .public_ipv4?, .ip?, .ipv4?, .attributes?.primary_ipv4?, .attributes?.public_ipv4?, .attributes?.ip?, .attributes?.ipv4?) | ip_value)
        }
    ]
    | first // {}
    | to_entries
    | map(select(.value != null and .value != ""))
    | map("\(.key)=\(.value)")
    | join(" ")
  ' 2>/dev/null || true)"

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    printf 'status unavailable\n'
  fi
}

wait_for_ssh() {
  local ip="$1"
  local role="${2:-host}"
  local deadline remaining connect_timeout output status last_log_at

  log "waiting up to ${SSH_READY_TIMEOUT_SECONDS}s for SSH as $SSH_USER on $role host $ip"
  deadline=$((SECONDS + SSH_READY_TIMEOUT_SECONDS))
  last_log_at=$SECONDS
  status=0
  output=""
  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    connect_timeout="$SSH_CONNECT_TIMEOUT_SECONDS"
    if (( connect_timeout > remaining )); then
      connect_timeout="$remaining"
    fi

    set +e
    output="$(ssh "${SSH_OPTS[@]}" -o "ConnectTimeout=$connect_timeout" "$SSH_USER@$ip" 'if [ "$(id -u)" -eq 0 ]; then true; else sudo -n true; fi' 2>&1)"
    status=$?
    set -e
    if (( status == 0 )); then
      log "SSH is ready as $SSH_USER on $role host $ip"
      return
    fi

    if (( SECONDS - last_log_at >= 30 )); then
      log "still waiting for SSH as $SSH_USER on $role host $ip; last status $status: $(summarize_lsh_output "$output")"
      last_log_at=$SECONDS
    fi

    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      break
    fi
    if (( remaining < 5 )); then
      sleep "$remaining"
    else
      sleep 5
    fi
  done
  log "last SSH attempt as $SSH_USER on $role host $ip failed with status $status: $(summarize_lsh_output "$output")"
  return 1
}

remote_root_bash_command() {
  if [[ "$SSH_USER" == "root" ]]; then
    printf 'bash -s'
  else
    printf 'sudo -n bash -s'
  fi
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
  local bench_nofile
  bench_nofile="$(required_nofile)"
  log "preparing server host $ip"
  scp "${SSH_OPTS[@]}" "$archive" "$SSH_USER@$ip:/tmp/bench-src.tar.gz" >/dev/null
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "$(remote_root_bash_command) -- $bench_nofile" <<'REMOTE'
set -euo pipefail
BENCH_NOFILE="$1"
BENCH_USER="${SUDO_USER:-${USER:-root}}"
sysctl -w fs.nr_open="$BENCH_NOFILE" >/dev/null
sysctl -w fs.file-max="$((BENCH_NOFILE * 2))" >/dev/null
sysctl -w net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535 net.ipv4.ip_local_port_range="1024 65535" >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null || true
sysctl -w net.ipv4.tcp_max_tw_buckets="$((BENCH_NOFILE * 2))" >/dev/null || true
ulimit -n "$BENCH_NOFILE"
{
  printf '* soft nofile %s\n' "$BENCH_NOFILE"
  printf '* hard nofile %s\n' "$BENCH_NOFILE"
  printf 'root soft nofile %s\n' "$BENCH_NOFILE"
  printf 'root hard nofile %s\n' "$BENCH_NOFILE"
} >/etc/security/limits.d/99-bench.conf
rm -rf /opt/bench
mkdir -p /opt/bench
tar -xzf /tmp/bench-src.tar.gz -C /opt/bench
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git build-essential jq procps unzip xz-utils
curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
install -d -m 755 /opt/bun
curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash
ln -sf /opt/bun/bin/bun /usr/local/bin/bun
curl -fsSL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH="/root/.cargo/bin:/usr/local/go/bin:/opt/bun/bin:$PATH"
export BUN_INSTALL="/opt/bun"
cd /opt/bench
mkdir -p /opt/bench/.tmp
node scripts/prepare-server-dependencies.mjs
go build -o /opt/bench/.tmp/collector ./collector/cmd/collector
chown -R "$BENCH_USER" /opt/bench
REMOTE
}

upload_and_prepare_loadgen() {
  local ip="$1"
  local archive="$2"
  local bench_nofile
  bench_nofile="$(required_nofile)"
  log "preparing loadgen host $ip"
  scp "${SSH_OPTS[@]}" "$archive" "$SSH_USER@$ip:/tmp/bench-src.tar.gz" >/dev/null
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "$(remote_root_bash_command) -- $bench_nofile" <<'REMOTE'
set -euo pipefail
BENCH_NOFILE="$1"
BENCH_USER="${SUDO_USER:-${USER:-root}}"
sysctl -w fs.nr_open="$BENCH_NOFILE" >/dev/null
sysctl -w fs.file-max="$((BENCH_NOFILE * 2))" >/dev/null
sysctl -w net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535 net.ipv4.ip_local_port_range="1024 65535" >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null || true
sysctl -w net.ipv4.tcp_max_tw_buckets="$((BENCH_NOFILE * 2))" >/dev/null || true
ulimit -n "$BENCH_NOFILE"
{
  printf '* soft nofile %s\n' "$BENCH_NOFILE"
  printf '* hard nofile %s\n' "$BENCH_NOFILE"
  printf 'root soft nofile %s\n' "$BENCH_NOFILE"
  printf 'root hard nofile %s\n' "$BENCH_NOFILE"
} >/etc/security/limits.d/99-bench.conf
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
go build -o /opt/bench/.tmp/loadgen-bin ./loadgen/cmd/loadgen
chown -R "$BENCH_USER" /opt/bench
REMOTE
}

run_server_suite() {
  local server="$1"
  local local_work_dir=".tmp/latitude-$server"
  rm -rf "$local_work_dir"
  mkdir -p "$local_work_dir"

  log "running suite for $server"
  remote_server_start "$server" "$local_work_dir"

  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local status=0
  set +e
  run_loadgen
  status=$?
  set -e

  remote_server_stop
  local artifact_status=0
  fetch_loadgen_artifacts "$local_work_dir" || artifact_status=$?
  fetch_server_artifacts "$local_work_dir"
  if [[ -f "$local_work_dir/summary.json" ]]; then
    write_suite_metadata "$server" "$started_at" "$local_work_dir"
  else
    log "loadgen summary is missing for $server; preserving available artifacts without metadata enrichment"
    artifact_status=1
  fi

  rm -rf "servers/$server/benchmark"
  mv "$local_work_dir" "servers/$server/benchmark"
  log "wrote servers/$server/benchmark"
  if (( artifact_status != 0 )); then
    fail "suite completed for $server but loadgen artifacts were incomplete; artifacts were preserved"
  fi
  if (( status == 2 )); then
    log "suite completed for $server with a target miss; artifacts were preserved"
  elif (( status != 0 )); then
    fail "suite completed for $server but loadgen exited with status $status; artifacts were preserved"
  fi
}

remote_server_start() {
  local server="$1"
  local local_work_dir="$2"
  local bench_nofile
  bench_nofile="$(required_nofile)"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IPV4" \
    BENCH_NOFILE="$bench_nofile" \
    SERVER_NAME="$server" \
    HOST="0.0.0.0" \
    PORTS="$REMOTE_PORTS" \
    'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n "$BENCH_NOFILE"
export PATH="/root/.cargo/bin:/usr/local/go/bin:/opt/bun/bin:$PATH"
export BUN_INSTALL="/opt/bun"
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
    ACTIVITY_METRICS_PATH="/opt/bench/.tmp/cloud-server/activity_metrics.jsonl" \
    SERVER_EVENTS_PATH="/opt/bench/.tmp/cloud-server/server_events.jsonl" \
    RUNTIME_METRICS_PATH="/opt/bench/.tmp/cloud-server/runtime_metrics.jsonl" \
    bash -lc "$run_command"
) > /opt/bench/.tmp/cloud-server/server.log 2>&1 &
echo "$!" > /opt/bench/.tmp/cloud-server/server.pid
first_port="${PORTS%%,*}"
for _ in {1..300}; do
  if curl -fsS "http://127.0.0.1:$first_port/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$(cat /opt/bench/.tmp/cloud-server/server.pid)" 2>/dev/null; then
    echo "server process exited before health check passed" >&2
    tail -n 100 /opt/bench/.tmp/cloud-server/server.log >&2 || true
    exit 1
  fi
  sleep 0.2
done
if ! curl -fsS "http://127.0.0.1:$first_port/health" >/dev/null; then
  echo "server health check failed for $SERVER_NAME on port $first_port" >&2
  ps -fp "$(cat /opt/bench/.tmp/cloud-server/server.pid)" >&2 || true
  ss -ltnp '( sport >= :8080 and sport <= :8111 )' >&2 || true
  tail -n 100 /opt/bench/.tmp/cloud-server/server.log >&2 || true
  exit 1
fi
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
  collector_pid="$(cat /opt/bench/.tmp/cloud-server/collector.pid)"
  kill "$collector_pid" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 "$collector_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$collector_pid" 2>/dev/null || true
fi
if [[ -f /opt/bench/.tmp/cloud-server/server.pid ]]; then
  server_pid="$(cat /opt/bench/.tmp/cloud-server/server.pid)"
  kill "$server_pid" 2>/dev/null || true
  for _ in {1..100}; do
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$server_pid" 2>/dev/null || true
fi
REMOTE
}

fetch_server_artifacts() {
  local local_work_dir="$1"
  for file in server_metrics.jsonl activity_metrics.jsonl server_events.jsonl runtime_metrics.jsonl server.log collector.log; do
    scp "${SSH_OPTS[@]}" "$SSH_USER@$SERVER_IPV4:/opt/bench/.tmp/cloud-server/$file" "$local_work_dir/$file" >/dev/null || true
  done
}

run_loadgen() {
  local connection_targets="${SCENARIO_CONNECTIONS[*]}"
  local remote_connection_targets
  local bench_nofile
  remote_connection_targets="$(connection_targets_csv)"
  bench_nofile="$(required_nofile)"
  log "running connection load from loadgen host: $connection_targets"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$LOADGEN_IPV4" \
    BENCH_NOFILE="$bench_nofile" \
    SERVER_PUBLIC_IP="$SERVER_IPV4" \
    CONNECTION_TARGETS="$remote_connection_targets" \
    REQUESTS_PER_SECOND="$REQUESTS_PER_SECOND" \
    TARGET_CONNECTION_RATE="$TARGET_CONNECTION_RATE" \
    CONNECTION_RETRIES="$CONNECTION_RETRIES" \
    CONNECTION_RETRY_DELAY="$CONNECTION_RETRY_DELAY" \
    PAYLOAD_BYTES="$PAYLOAD_BYTES" \
    PAYLOAD_SWEEP_BYTES="$(payload_sweep_csv)" \
    PAYLOAD_SWEEP_SECONDS="$PAYLOAD_SWEEP_SECONDS" \
    BASELINE_SECONDS="$BASELINE_SECONDS" \
    SETTLE_SECONDS="$SETTLE_SECONDS" \
    STABILIZE_SECONDS="$STABILIZE_SECONDS" \
    TRAFFIC_SECONDS="$TRAFFIC_SECONDS" \
    COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
    PORTS="$REMOTE_PORTS" \
    'bash -s' <<'REMOTE'
set -euo pipefail
ulimit -n "$BENCH_NOFILE"
cd /opt/bench
OUT="/opt/bench/.tmp/loadgen"
rm -rf "$OUT"
mkdir -p "$OUT"
test -x /opt/bench/.tmp/loadgen-bin
URLS=""
IFS=',' read -r -a ports <<<"$PORTS"
for port in "${ports[@]}"; do
  port="${port//[[:space:]]/}"
  [[ -n "$port" ]] || continue
  if [[ -n "$URLS" ]]; then URLS+=","; fi
  URLS+="http://$SERVER_PUBLIC_IP:$port/json"
done
/opt/bench/.tmp/loadgen-bin \
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
  --output "$OUT" > "$OUT/loadgen.log" 2>&1
REMOTE
}

fetch_loadgen_artifacts() {
  local local_work_dir="$1"
  if ! ssh "${SSH_OPTS[@]}" "$SSH_USER@$LOADGEN_IPV4" "test -d /opt/bench/.tmp/loadgen"; then
    log "loadgen artifacts directory is missing on loadgen host"
    return 1
  fi
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$LOADGEN_IPV4" "tar -C /opt/bench/.tmp/loadgen -czf - ." | tar -xzf - -C "$local_work_dir"
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
  CONNECTION_TARGETS="${SCENARIO_CONNECTIONS[*]}" \
  PAYLOAD_SWEEP_BYTES="$PAYLOAD_SWEEP_BYTES" \
  PAYLOAD_SWEEP_SECONDS="$PAYLOAD_SWEEP_SECONDS" \
  node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');

const suiteDir = process.env.SUITE_DIR;
const serverName = process.env.SERVER_NAME;
const manifest = JSON.parse(fs.readFileSync(path.join('servers', serverName, 'bench.json'), 'utf8'));
const summary = JSON.parse(fs.readFileSync(path.join(suiteDir, 'summary.json'), 'utf8'));
const connectionTargets = process.env.CONNECTION_TARGETS.split(/\s+/).filter(Boolean).map(Number);

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
  connections: summary.connections ?? Math.max(...connectionTargets),
  connection_targets: summary.connection_targets ?? connectionTargets,
  payload_bytes: summary.payload_bytes ?? null,
  payload_sweep_bytes: summary.payload_sweep_bytes ?? process.env.PAYLOAD_SWEEP_BYTES.split(/[\s,]+/).filter(Boolean).map(Number),
  payload_sweep_seconds: summary.payload_sweep_seconds ?? Number(process.env.PAYLOAD_SWEEP_SECONDS),
  target_requests_per_second: summary.target_requests_per_second ?? summary.target_messages_per_second ?? null,
  target_messages_per_second: summary.target_requests_per_second ?? summary.target_messages_per_second ?? null,
  target_connection_rate: summary.target_connection_rate ?? null,
  connection_retries: summary.connection_retries ?? null,
  connection_retry_delay_ms: summary.connection_retry_delay_ms ?? null,
  baseline_seconds: summary.baseline_seconds ?? null,
  settle_seconds: summary.settle_seconds ?? null,
  stabilize_seconds: summary.stabilize_seconds ?? null,
  traffic_seconds: summary.traffic_seconds ?? null,
  cooldown_seconds: summary.cooldown_seconds ?? null,
  started_at: process.env.STARTED_AT,
  git_commit: process.env.GIT_COMMIT,
  benchmark_recommendations: {
    topology: 'dedicated Latitude server host plus dedicated Latitude loadgen host in the same site',
    request_shape: 'HTTP/1.1 keep-alive POST /json with JSON parse, validation, checksum, and JSON response serialization',
    primary_metrics: ['active_connections', 'requests_started_per_second', 'responses_completed_per_second', 'rss_mb', 'cpu_percent', 'threads', 'open_fds'],
    notes: [
      'Load generation is isolated from the measured server host.',
      'Connections are distributed over multiple server ports to avoid client ephemeral-port exhaustion at 1M connections.',
      'Connection targets are cumulative inside one continuous run so resource growth can be correlated with server activity.',
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

const enrichedSummary = {
  ...summary,
  server: serverName,
  suite: metadata.suite,
  started_at: summary.started_at ?? process.env.STARTED_AT,
  connection_targets: summary.connection_targets ?? connectionTargets,
};

fs.writeFileSync(path.join(suiteDir, 'metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
fs.writeFileSync(path.join(suiteDir, 'summary.json'), `${JSON.stringify(enrichedSummary, null, 2)}\n`);
NODE
}

main "$@"
