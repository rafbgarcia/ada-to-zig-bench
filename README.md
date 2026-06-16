# HTTP JSON Runtime Benchmark

This repository benchmarks language/runtime implementations with a small, repeatable HTTP JSON server workload.

This is not a general language-speed score. It measures the resource cost of one HTTP/1.1 server process doing fixed-rate JSON request work across a payload-size sweep.

Suite 1 is `http-json`. Endpoint behavior, server process rules, manifests, metrics, and fairness requirements are defined in the language-neutral [server implementation contract](docs/server-implementation-contract.md).

The benchmark is intentionally minimal: one server process, persistent HTTP/1.1 keep-alive clients, a fixed request rate, 10 seconds for each configured payload size, server activity metrics, and external process metrics for CPU/RSS/threads/open FDs.

## Server Implementations

Each implementation lives under `servers/<name>/`. To add or review an implementation, use the [server implementation contract](docs/server-implementation-contract.md) as the normative source and run `./scripts/test-server-implementations.sh <server>` before collecting benchmark artifacts.

The current implementations are:

- `servers/ada-gnat`: Ada GNAT.Sockets server using GNATCOLL.JSON
- `servers/node`: Node.js stdlib HTTP server
- `servers/bun`: Bun native HTTP server
- `servers/c-libmicrohttpd`: C server using libmicrohttpd and jansson
- `servers/cpp-boost-beast`: C++ Boost.Beast/Asio server using nlohmann-json
- `servers/csharp-aspnetcore`: C# ASP.NET Core minimal API server on Kestrel
- `servers/go-nethttp`: Go stdlib `net/http` server
- `servers/java-httpserver`: Java JDK `HttpServer` using Gson
- `servers/python-aiohttp`: Python `aiohttp.web` server
- `servers/ruby-webrick`: Ruby WEBrick server
- `servers/rust-hyper-tokio-st`: Rust Hyper HTTP/1.1 server on a single-thread Tokio runtime
- `servers/rust-hyper-tokio-mt`: Rust Hyper HTTP/1.1 server on a multi-thread Tokio runtime
- `servers/zig-std`: Zig `std.http.Server` server

## Local Smoke Test

Requirements: Go 1.24 and Node.js 24 for the harness, plus the toolchains listed in the selected server's `bench.json`. On Ubuntu, `sudo bash scripts/setup-toolchains.sh <toolchain ...>` installs the repository's known toolchain/dependency set. When no toolchains are supplied, it reads every server manifest.

To validate a server implementation without collecting benchmark artifacts:

```sh
./scripts/test-server-implementations.sh go-nethttp
```

```sh
go mod download
./scripts/run-local.sh node 64 128 100
```

Arguments:

```text
./scripts/run-local.sh <server> <client_connections> <payload_bytes> <requests_per_second>
```

Defaults:

```text
server:                    node
client_connections:        8192
payload_bytes:             256
payload_sweep_bytes:       "256 1024 4096 8192"
payload_sweep_seconds:     10
warmup_seconds:            5
warmup_requests/sec:       1000
requests/sec:              100000
work_mode:                 open-loop
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
LATITUDE_REBOOT_BETWEEN_SERVERS=1
SSH_USER=ubuntu
SSH_READY_TIMEOUT_SECONDS=600
SSH_CONNECT_TIMEOUT_SECONDS=5
CLIENT_CONNECTIONS=8192
REQUESTS_PER_SECOND=100000
WORK_MODE=open-loop
PAYLOAD_BYTES=256
PAYLOAD_SWEEP_BYTES="256 1024 4096 8192"
PAYLOAD_SWEEP_SECONDS=10
WARMUP_SECONDS=5
WARMUP_REQUESTS_PER_SECOND=1000
CONNECTION_RETRIES=3
CONNECTION_RETRY_DELAY=1s
```

The server listens on 32 ports by default (`8080..8111`) so large client pools can spread outbound TCP sockets over multiple destination tuples. Override `REMOTE_PORTS` when running on Latitude, or the optional `ports` array in `servers/<server>/bench.json` for local runs, if you need a different fanout.

The Latitude runner raises Linux limits on both hosts before the measured run. It sets `fs.nr_open`, `fs.file-max`, `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog`, `net.ipv4.ip_local_port_range`, `net.ipv4.tcp_tw_reuse`, and a per-process `nofile` limit derived from `CLIENT_CONNECTIONS`. When more than one server suite is run, the runner reboots both Latitude hosts between suites by default and reapplies the benchmark kernel/file-limit tuning after SSH returns. Set `LATITUDE_REBOOT_BETWEEN_SERVERS=0` only for exploratory runs where cross-run TCP/kernel-state carryover is acceptable.

`server_metrics.jsonl` contains external process/resource samples, including CPU, RSS, threads, open FDs, Linux TCP socket state counts, and Linux `TcpExt` backlog/drop counters where available. `activity_metrics.jsonl` contains in-process server work counters: active requests, request totals, response totals, status buckets, and server-side request errors. Treat these server-side counters as validation and resource correlation. The primary throughput truth is `loadgen_metrics.jsonl`, which records cumulative scheduled, dispatched, sent, received, error, and dispatch-miss counters from the isolated load generator; rates should be derived from those cumulative counters and sample timestamps.

Before the measured payload sweep, the load generator runs a configurable warmup using valid `POST /json` traffic. Warmup counters are recorded separately in `summary.json.warmup_*`; primary load-generator totals and latency percentiles are reset before the measured sweep.

`summary.json.total_errors` captures all response, protocol, checksum, dispatch, and connection-attempt failures observed by the load generator. Failed dial or `/health` connection setup attempts are retried up to `CONNECTION_RETRIES` times with `CONNECTION_RETRY_DELAY` between attempts; defaults are 3 retries and 1 second. `summary.json.total_connection_attempts`, `summary.json.total_connection_retries`, and `summary.json.total_connection_failures` separate retry recovery from terminal failed client slots. `loadgen_errors.jsonl` is a bounded sample of failures and includes attempt metadata for connection attempts; `summary.json.loadgen_error_samples` and `summary.json.loadgen_errors_dropped` show how much was written or omitted. `summary.json.total_dispatch_misses` and `loadgen_metrics.jsonl.dispatch_misses_per_second` capture target-rate saturation where every live keep-alive client already had an in-flight request at dispatch time. `summary.json.complete` means every configured measured stage ran; `summary.json.success` requires a complete run with zero load-generator errors, zero terminal connection failures, and `total_sent == total_received`. The Latitude runner only treats clean successful artifacts as reusable benchmark results.

`WORK_MODE=open-loop` is the default benchmark mode. It schedules request slots at the configured rate and records dispatch misses when all connections are busy, then waits for all dispatched in-flight requests to finish before moving to the next stage. This mode is best for saturation analysis: target rate, actual dispatch rate, completed rate, missed slots, latency growth, and drain time.

`WORK_MODE=fixed-work` keeps the same per-stage target request count but does not drop missed slots. If the server is saturated, the load generator delays dispatch until a keep-alive client is available and then continues until every scheduled request for that stage has been dispatched and completed. This mode is best for same-work comparisons: each server receives the same request count, and stage elapsed/drain time shows how long it took to finish.

`CLIENT_CONNECTIONS` controls the size of the load generator's keep-alive client pool. The measured benchmark stages are only the configured `PAYLOAD_SWEEP_BYTES`; each payload size runs at `REQUESTS_PER_SECOND` for `PAYLOAD_SWEEP_SECONDS` after the pre-measurement warmup.

## GitHub Workflow

`.github/workflows/server-implementation-tests.yml` runs on pull requests, pushes to `main`, manual dispatch, and as a reusable workflow. It discovers every `servers/<name>/bench.json` implementation and tests them as a bounded matrix with up to eight jobs in parallel. Each matrix job installs Node.js and Go for the checker/load generator, provisions the selected server's manifest-declared toolchains, starts the implementation on local ports, checks the HTTP JSON contract directly, and runs a tiny load-generator pass. The test artifacts are written under `.tmp/` and do not replace `servers/*/benchmark` results.

Run `.github/workflows/benchmarks.yml` manually. It installs `lsh`, creates Latitude hosts, runs missing benchmark suites, builds the replay UI, deploys to Vercel, and commits new `servers/*/benchmark` artifacts.

The benchmark workflow requires the server implementation tests before checking for missing benchmark artifacts or provisioning Latitude hosts. Docker is not used for this preflight because the benchmark contract is the local server command from `bench.json`, not a container image. Add Docker only if the benchmark runner later starts servers from images or needs to validate image packaging.

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

Useful repository variables mirror the local environment names: `LATITUDE_PROJECT`, `LATITUDE_SITE`, `LATITUDE_SERVER_PLAN`, `LATITUDE_LOADGEN_PLAN`, `CLIENT_CONNECTIONS`, `REQUESTS_PER_SECOND`, `PAYLOAD_BYTES`, `PAYLOAD_SWEEP_BYTES`, `PAYLOAD_SWEEP_SECONDS`, `WARMUP_SECONDS`, and `WARMUP_REQUESTS_PER_SECOND`.

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
- Keep `REQUESTS_PER_SECOND`, `PAYLOAD_SWEEP_BYTES`, `PAYLOAD_SWEEP_SECONDS`, and `CLIENT_CONNECTIONS` fixed across implementations.
- Treat latency as a secondary backpressure/correctness signal. Primary metrics are request/response throughput, CPU percent, RSS, threads, and open FDs for each payload size.
- Treat CPU model as part of the implementation identity. Single-threaded and multi-threaded variants should be separate benchmark entries.
- Install each language/runtime and implementation dependencies before the measured run. The runner does this during host preparation from each `bench.json` manifest.
- Delete `servers/<server>/benchmark` to force a rerun. Otherwise, the Latitude runner skips implementations whose summary matches the configured payload sweep and request rate.
