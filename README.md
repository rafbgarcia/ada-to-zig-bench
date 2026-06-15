# HTTP JSON Runtime Benchmark

This repository benchmarks language/runtime implementations with a small, repeatable HTTP JSON server workload.

This is not a general language-speed score. It measures the resource cost of one HTTP/1.1 server process holding many long-lived TCP connections while doing a fixed amount of JSON request work.

Suite 1 is `http-json`:

- `POST /json` accepts `{ "id": number, "payload": string }` with a 1 MiB maximum request body.
- The server parses JSON, validates `id` as a non-negative integer and `payload` as a string, computes 32-bit FNV-1a over the UTF-8 payload bytes, and serializes `{ "id", "len", "checksum" }`.
- Responses should be JSON with `Content-Length`, `Content-Type: application/json`, and HTTP/1.1 keep-alive.
- `/health` is used by orchestration.
- `/runtime` and runtime JSONL files expose runtime-specific memory/GC counters where available.

The benchmark is intentionally minimal: one server process, persistent HTTP/1.1 connections, a fixed connection ramp to the target, a fixed request-rate ramp to the target, a short payload-size sweep after the target RPS is reached, server activity metrics, and external process metrics for CPU/RSS/threads/open FDs.

## Server Layout

Each implementation lives under `servers/<name>/` and is described by `bench.json`:

```json
{
  "id": "node",
  "language": "JavaScript",
  "runtime": "Node.js",
  "suite": "http-json",
  "install": "",
  "run": "node src/server.js"
}
```

Use `install` for language/package setup needed inside that implementation directory. Keep it empty when the implementation only needs a runtime already installed on the benchmark host.

`ports` is optional in `bench.json`. Runners default to `8080..8111` and pass the chosen list through the `PORTS` environment variable. Implementations should listen on every comma-separated port in `PORTS`; define `ports` in a manifest only when an implementation needs a custom local default.

The current implementations are:

- `servers/node`: Node.js stdlib HTTP server
- `servers/bun`: Bun native HTTP server
- `servers/rust-hyper-tokio-st`: Rust Hyper HTTP/1.1 server on a single-thread Tokio runtime
- `servers/rust-hyper-tokio-mt`: Rust Hyper HTTP/1.1 server on a multi-thread Tokio runtime

## Local Smoke Test

Requirements: Go 1.24, Node.js 24, Bun if running `servers/bun`, and Rust stable if running the Rust servers.

```sh
go mod download
./scripts/run-local.sh node "50 100" 128 100 10
```

Arguments:

```text
./scripts/run-local.sh <server> <connection_target> <payload_bytes> <requests_per_second> <request_ramp_seconds>
```

Defaults:

```text
server:                    node
connection_target:         "1000000"
payload_bytes:             256
payload_sweep_bytes:       "256 1024 4096 16384"
payload_sweep_seconds:     5
requests/sec:              100000 final target
work_mode:                 open-loop
request_ramp_seconds:      10
baseline:                  0s
connection_ramp:           50000 new connections/sec target
settle_after_ramp:         0s
stabilize_after_traffic:   0s
cooldown:                  0s
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
BENCHMARK_CONNECTIONS=1000000
REQUESTS_PER_SECOND=100000
WORK_MODE=open-loop
PAYLOAD_BYTES=256
PAYLOAD_SWEEP_BYTES="256 1024 4096 16384"
PAYLOAD_SWEEP_SECONDS=5
TARGET_CONNECTION_RATE=50000
CONNECTION_RETRIES=3
CONNECTION_RETRY_DELAY=1s
TRAFFIC_SECONDS=10
BASELINE_SECONDS=0
SETTLE_SECONDS=0
STABILIZE_SECONDS=0
COOLDOWN_SECONDS=0
```

The server listens on 32 ports by default (`8080..8111`) so one loadgen IPv4 can hold 1M outbound TCP connections without exhausting the client ephemeral port range for one destination tuple. Override `REMOTE_PORTS` when running on Latitude, or the optional `ports` array in `servers/<server>/bench.json` for local runs, if you need a different fanout. As a rule of thumb, keep one target port per roughly 32k client connections when a single loadgen source IP is used, especially for back-to-back runs where previous sockets can still be in `TIME_WAIT`.

The Latitude runner raises Linux limits on both hosts before the measured run. It sets `fs.nr_open`, `fs.file-max`, `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog`, `net.ipv4.ip_local_port_range`, `net.ipv4.tcp_tw_reuse`, and a per-process `nofile` limit derived from the largest configured connection target. For 1M connections, you need this class of OS tuning; the default Linux `nofile` limit and a single destination port will not be enough.

`server_metrics.jsonl` contains external process/resource samples, including CPU, RSS, threads, open FDs, Linux TCP socket state counts, and Linux `TcpExt` backlog/drop counters where available. `activity_metrics.jsonl` contains in-process server work counters: active connections when the implementation can report them, active requests, request totals, response totals, status buckets, and server-side request errors. Treat these server-side counters as validation and resource correlation. The primary throughput truth is `loadgen_metrics.jsonl`, which records cumulative scheduled, dispatched, sent, received, error, and dispatch-miss counters from the isolated load generator; rates should be derived from those cumulative counters and sample timestamps.

`summary.json.total_errors` captures all response, protocol, checksum, and connection-attempt failures observed by the load generator. During connection ramp, failed dial or `/health` warmup attempts are retried up to `CONNECTION_RETRIES` times with `CONNECTION_RETRY_DELAY` between attempts; defaults are 3 retries and 1 second. `summary.json.total_connection_attempts`, `summary.json.total_connection_retries`, and `summary.json.total_connection_failures` separate retry recovery from terminal failed connection slots. `loadgen_errors.jsonl` is a bounded sample of failures and includes attempt metadata for connection attempts; `summary.json.loadgen_error_samples` and `summary.json.loadgen_errors_dropped` show how much was written or omitted. `summary.json.total_dispatch_misses` and `loadgen_metrics.jsonl.dispatch_misses_per_second` capture target-rate saturation where every live keep-alive connection already had an in-flight request at dispatch time. Completed runs are still published when these counters are non-zero so failures and saturation can be correlated with server-side resource metrics. `summary.json.success` is `false` when a server cannot reach the configured connection target; that target miss is still a benchmark result. Orchestration fails only when the load generator cannot produce a complete summary or required artifacts are missing.

`WORK_MODE=open-loop` is the default benchmark mode. It schedules request slots at the configured rate and records dispatch misses when all connections are busy, then waits for all dispatched in-flight requests to finish before moving to the next stage. This mode is best for saturation analysis: target rate, actual dispatch rate, completed rate, missed slots, latency growth, and drain time.

`WORK_MODE=fixed-work` keeps the same per-stage target request count but does not drop missed slots. If the server is saturated, the load generator delays dispatch until a connection becomes idle and then continues until every scheduled request for that stage has been dispatched and completed. This mode is best for same-work comparisons: each server receives the same request count, and stage elapsed/drain time shows how long it took to finish.

`BENCHMARK_CONNECTIONS` is the connection target. The default `1000000` means the loadgen opens connections at `TARGET_CONNECTION_RATE=50000` until it reaches 1M, then ramps request dispatch to `REQUESTS_PER_SECOND=100000` over `TRAFFIC_SECONDS=10`. After target RPS is reached, it sends each configured `PAYLOAD_SWEEP_BYTES` size for `PAYLOAD_SWEEP_SECONDS` while holding the same connection count and request rate. With defaults, the benchmark reaches 1M connections in about 20 seconds, reaches 100k requests per second 10 seconds later, then runs 20 seconds of payload-size sweep.

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

Useful repository variables mirror the local environment names: `LATITUDE_PROJECT`, `LATITUDE_SITE`, `LATITUDE_SERVER_PLAN`, `LATITUDE_LOADGEN_PLAN`, `BENCHMARK_CONNECTIONS`, `REQUESTS_PER_SECOND`, `PAYLOAD_BYTES`, `PAYLOAD_SWEEP_BYTES`, `PAYLOAD_SWEEP_SECONDS`, and `TRAFFIC_SECONDS`.

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
- Keep the connection and request-rate ramps fixed across implementations. This makes differences easier to compare because every runtime sees the same 50k connections/sec ramp followed by the same 10k requests/sec/sec ramp.
- Treat latency as a secondary backpressure/correctness signal. Primary metrics are server activity counters, CPU percent, RSS, threads, open FDs, RSS per 10k live connections, FDs per connection, and CPU percent per 10k successful RPS over the ramp timeline.
- Treat CPU model as part of the implementation identity. Single-threaded and multi-threaded variants should be separate benchmark entries.
- Install each language/runtime and implementation dependencies before the measured run. The runner does this during host preparation from each `bench.json` manifest.
- Delete `servers/<server>/benchmark` to force a rerun. Otherwise, the Latitude runner skips implementations whose summary contains the configured connection target.
