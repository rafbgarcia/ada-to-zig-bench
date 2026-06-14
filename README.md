# HTTP JSON Runtime Benchmark

This repository benchmarks language runtimes with a small, repeatable HTTP JSON server workload.

Suite 1 is `http-json`:

- `POST /json` accepts `{ "id": number, "payload": string }`.
- The server parses JSON, validates fields, computes a deterministic checksum, and serializes `{ "id", "len", "checksum" }`.
- `/health` is used by orchestration.
- `/runtime` and runtime JSONL files expose runtime-specific memory/GC counters where available.

The benchmark is intentionally minimal: one server process, persistent HTTP/1.1 connections, staged cumulative connection targets, fixed request rate per stage, server activity metrics, and external process metrics for CPU/RSS/threads/open FDs.

## Server Layout

Each implementation lives under `servers/<name>/` and is described by `bench.json`:

```json
{
  "id": "node",
  "language": "JavaScript",
  "runtime": "Node.js",
  "suite": "http-json",
  "install": "",
  "run": "node src/server.js",
  "ports": [8080, 8081, 8082, 8083]
}
```

Use `install` for language/package setup needed inside that implementation directory. Keep it empty when the implementation only needs a runtime already installed on the benchmark host.

The current implementations are:

- `servers/node`: Node.js stdlib HTTP server
- `servers/bun`: Bun native HTTP server

## Local Smoke Test

Requirements: Go 1.24, Node.js 24, and Bun if running `servers/bun`.

```sh
go mod download
./scripts/run-local.sh node "50 100" 128 100 10
```

Arguments:

```text
./scripts/run-local.sh <server> <connection_targets> <payload_bytes> <requests_per_second> <traffic_seconds_per_stage>
```

Defaults:

```text
server:                    node
connection_targets:        "1000 10000 50000 100000"
payload_bytes:             256
requests/sec:              10000
traffic_seconds_per_stage: 20
baseline:                  10s
ramp:                      10000 new connections/sec target
settle_after_ramp:         10s
stabilize_after_traffic:   10s
cooldown:                  20s
```

The command writes one benchmark dataset under:

```text
servers/<server>/benchmark/
  metadata.json
  summary.json
  server_metrics.jsonl
  activity_metrics.jsonl
  server_events.jsonl
  loadgen_metrics.jsonl
  loadgen_errors.jsonl
  runtime_metrics.jsonl
  runtime_events.jsonl
  server.log
  loadgen.log
  collector.log
```

## Latitude Benchmark Run

The cloud runner provisions two Latitude bare-metal hosts with hourly billing:

- one measured server host
- one isolated load-generator host in the same site

It runs only implementations missing complete benchmark artifacts and destroys both hosts at the end unless `LATITUDE_KEEP_INFRA=1` is set.

```sh
LATITUDESH_TOKEN=... \
LATITUDE_PROJECT=default-project \
LATITUDE_SSH_KEYS=key_xxx \
./scripts/run-latitude-benchmarks.sh
```

Useful defaults:

```text
LATITUDE_SITE=ASH
LATITUDE_SERVER_PLAN=f4-metal-small
LATITUDE_LOADGEN_PLAN=f4-metal-small
LATITUDE_OPERATING_SYSTEM=ubuntu_24_04_x64_lts
LATITUDE_BILLING=hourly
LATITUDE_PROVISION_ATTEMPTS=2
SSH_USER=ubuntu
SSH_READY_TIMEOUT_SECONDS=600
SSH_CONNECT_TIMEOUT_SECONDS=5
BENCHMARK_CONNECTIONS="1000 10000 50000 100000"
REQUESTS_PER_SECOND=10000
PAYLOAD_BYTES=256
TRAFFIC_SECONDS=20
STABILIZE_SECONDS=10
```

The server listens on four ports by default (`8080,8081,8082,8083`) so the loadgen can hold 100k outbound TCP connections without exhausting the client ephemeral port range for one destination tuple.

`server_metrics.jsonl` contains external process/resource samples, including CPU, RSS, threads, open FDs, and Linux TCP socket state counts where available. `activity_metrics.jsonl` contains in-process server work counters: active connections when the implementation can report them, active requests, request totals, response totals, status buckets, and server-side request errors.

`summary.json.total_errors` and `loadgen_errors.jsonl` capture response, protocol, and connection failures observed by the load generator. `summary.json.total_dispatch_misses` and `loadgen_metrics.jsonl.dispatch_misses_per_second` capture target-rate saturation where every live keep-alive connection already had an in-flight request at dispatch time. Completed runs are still published when these counters are non-zero so failures and saturation can be correlated with server-side resource metrics. A run fails orchestration when the load generator cannot reach the configured final connection target or cannot produce a complete summary.

`BENCHMARK_CONNECTIONS` is a cumulative connection schedule. The default `1000 10000 50000 100000` means the loadgen opens connections until it reaches 1k, sends traffic for `TRAFFIC_SECONDS`, idles for `STABILIZE_SECONDS`, opens more connections until it reaches 10k total, and repeats until the final target. Connections stay open between stages.

## GitHub Workflow

Run `.github/workflows/benchmarks.yml` manually. It installs `lsh`, creates Latitude hosts, runs missing benchmark suites, builds the replay UI, deploys to Vercel, and commits new `servers/*/benchmark` artifacts.

Required secrets:

```text
LATITUDESH_TOKEN
LATITUDE_SSH_PRIVATE_KEY
VERCEL_TOKEN
VERCEL_ORG_ID
VERCEL_PROJECT_ID
```

Required repository variable or secret:

```text
LATITUDE_SSH_KEYS
```

Useful repository variables mirror the local environment names: `LATITUDE_PROJECT`, `LATITUDE_SITE`, `LATITUDE_SERVER_PLAN`, `LATITUDE_LOADGEN_PLAN`, `BENCHMARK_CONNECTIONS`, `REQUESTS_PER_SECOND`, `PAYLOAD_BYTES`, and `TRAFFIC_SECONDS`.

## Replay UI

```sh
npm ci --prefix web
npm run dev --prefix web
```

Open `http://127.0.0.1:5173` to inspect the generated benchmark data. To build static files only:

```sh
npm run build --prefix web
```

## Benchmark Recommendations

- Use dedicated bare metal for the measured server and a separate dedicated host for load generation.
- Keep loadgen and server in the same Latitude site. Public IPv4 is the default because Latitude virtual networks require extra OS/VLAN setup; private networking can be added later if public-network variance becomes material.
- Keep the request rate fixed across connection stages at first. This makes 1k/10k/50k/100k mostly measure accumulated connection/runtime overhead instead of mixing in more application work.
- Treat latency as a secondary backpressure/correctness signal. Primary metrics are server activity counters, CPU percent, RSS, threads, and open FDs over the staged timeline.
- Install each language/runtime and implementation dependencies before the measured run. The runner does this during host preparation from each `bench.json` manifest.
- Delete `servers/<server>/benchmark` to force a rerun. Otherwise, the Latitude runner skips implementations whose summary contains all configured connection targets.
