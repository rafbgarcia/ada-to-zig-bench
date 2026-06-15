# Server Implementation Contract

This document is the formal contract for implementations of the `http-json` benchmark suite. It uses the requirement words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY in the RFC 2119 sense.

The document format is Markdown because this contract is intended to be reviewed with code, linked from implementation pull requests, and consumed by maintainers adding servers in many languages. Machine-readable validation remains in the existing JSON schemas under `schemas/` and in `scripts/check-http-json-server.mjs`.

## Scope

An implementation is one benchmark entry under `servers/<name>/`. It consists of a `bench.json` manifest and the code needed to start one measured HTTP server process for the `http-json` suite.

The benchmark measures the resource cost of a long-running HTTP/1.1 JSON server process under many persistent TCP connections and a fixed request workload. It is not a general language-speed benchmark.

## Implementation Manifest

Each implementation MUST include `servers/<name>/bench.json` with these fields:

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

`id` MUST be stable and unique across implementations. `suite` MUST be `http-json` unless a future suite defines a different contract. `install` MUST contain only the setup required inside that implementation directory and MAY be an empty string. `run` MUST start the measured server in the current implementation directory.

The manifest MAY include `ports` when the implementation needs a custom local default. Runners pass the actual target ports through `PORTS`, so implementation code MUST treat the environment as authoritative when it is present.

## Process Model

The `run` command MUST start one measured OS process. That process MAY create threads and asynchronous tasks. It MUST NOT fan out the workload to additional worker processes unless the benchmark harness is changed to collect resource metrics for the entire process tree.

Single-threaded and multi-threaded variants SHOULD be separate implementation entries with distinct `id`, `runtime`, and server directory names. Runtime flags that materially affect concurrency, garbage collection, JIT behavior, memory limits, or allocator behavior SHOULD either be encoded in a distinct implementation entry or documented in the manifest/runtime name.

The process MUST run until it receives `SIGTERM` or `SIGINT`. It SHOULD exit promptly after either signal. Cleanup MAY close open sockets immediately; graceful drain is not required after the measured run has ended.

## Configuration

The server MUST support these environment variables:

| Variable | Required behavior |
| --- | --- |
| `HOST` | Listen address. Default SHOULD be `127.0.0.1` when unset. Cloud runs pass `0.0.0.0`. |
| `PORTS` | Comma-separated TCP ports to listen on. The server MUST listen on every valid listed port. |
| `PORT` | Single-port fallback when `PORTS` is unset. |
| `ACTIVITY_METRICS_PATH` | Optional path for server activity JSONL output. |
| `SERVER_EVENTS_PATH` | Optional path for server event JSONL output. |
| `RUNTIME_METRICS_PATH` | Optional path for runtime-specific JSONL output. |

When both `PORTS` and `PORT` are unset, the server SHOULD listen on port `8080`. Invalid configured ports SHOULD cause startup failure with a non-zero process exit.

When an output path variable is unset or empty, the corresponding file writer MUST be disabled. When it is set, the server MUST append newline-delimited JSON records to that path and SHOULD avoid blocking request handling on slow metrics I/O.

## HTTP Protocol

The server MUST implement HTTP/1.1 over TCP. The server MUST support persistent keep-alive connections and MUST be able to process repeated sequential requests on one connection.

The benchmark does not require TLS, HTTP/2, HTTP/3, compression, routing middleware, access logging, templating, static files, or application-level authentication. Implementations SHOULD disable optional features that add work outside this contract.

Every response from the benchmark endpoints MUST include:

- `Content-Type: application/json`, optionally with parameters such as `charset=utf-8`.
- `Content-Length` equal to the byte length of the response body.
- A JSON response body.

Responses SHOULD keep the connection alive when the request uses keep-alive and the protocol permits it.

## Endpoints

### `GET /health`

`GET /health` MUST return status `200` and a JSON object containing at least:

```json
{ "ok": true }
```

It MAY include current counters such as `active_connections`, `active_requests`, `accepted_connections_total`, `closed_connections_total`, `requests_started_total`, `responses_completed_total`, and `total_errors`.

The load generator uses `/health` during connection warmup. The endpoint MUST be cheap and MUST NOT mutate request/response benchmark counters.

### `GET /runtime`

`GET /runtime` MUST return status `200` and a JSON object containing at least:

```json
{ "runtime": "<implementation runtime id>" }
```

It SHOULD include `ts`, `elapsed_seconds`, and any low-cost runtime memory or garbage-collection counters available in that language. Runtime metrics are implementation-specific and SHOULD follow `schemas/runtime_metrics.schema.json` where fields overlap.

### `POST /json`

`POST /json` is the measured workload endpoint.

The server MUST read and parse a JSON request body with this logical shape:

```json
{ "id": 7, "payload": "hello" }
```

Validation requirements:

- The server MUST support every configured load-generator payload size. Current benchmark defaults sweep up to 8192 payload bytes.
- `id` MUST be a JSON number representing an integer in the inclusive range `0..9007199254740991`.
- `payload` MUST be a JSON string.
- Extra request object fields MAY be ignored.
- Invalid JSON, missing fields, invalid field types, negative IDs, and fractional IDs MUST fail with a `400` JSON response.

The successful response MUST have status `200` and this logical shape:

```json
{ "id": 7, "len": 5, "checksum": 1335831723 }
```

Response requirements:

- `id` MUST equal the request `id`.
- `len` MUST equal the UTF-8 byte length of `payload` after JSON string decoding.
- `checksum` MUST equal 32-bit FNV-1a over those UTF-8 payload bytes.

The 32-bit FNV-1a algorithm is:

```text
value = 2166136261
for byte in utf8(payload):
  value = value XOR byte
  value = (value * 16777619) modulo 2^32
return value as an unsigned 32-bit integer
```

Reference vectors:

| Payload | UTF-8 bytes | FNV-1a checksum |
| --- | ---: | ---: |
| empty string | 0 | `2166136261` |
| `hello` | 5 | `1335831723` |
| `ola mundo` | 9 | `504920372` |
| `payload with newline\nand tab\tcharacters` | 39 | `813030118` |
| JSON string `"\uD83D\uDE00"` | 4 | `866293256` |

### Other routes and methods

Requests outside `GET /health`, `GET /runtime`, and `POST /json` MUST return a JSON error response. Current implementations return `404` for `GET /json` and missing routes; new implementations SHOULD do the same.

## Metrics Files

When `ACTIVITY_METRICS_PATH` is set, the server MUST write activity samples as JSONL. Samples SHOULD be written at approximately one-second intervals and SHOULD include:

- `ts`
- `elapsed_seconds`
- `elapsed_ms` when available
- `active_connections`, set to `null` unless connection tracking is explicitly enabled for every implementation
- `accepted_connections_total`, set to `null` unless connection tracking is explicitly enabled for every implementation
- `closed_connections_total`, set to `null` unless connection tracking is explicitly enabled for every implementation
- `active_requests`
- `requests_started_total`
- `responses_completed_total`
- `responses_2xx_total`
- `responses_4xx_total`
- `responses_5xx_total`
- `request_errors_total`

The activity metrics schema is `schemas/activity_metrics.schema.json`.

`requests_started_total` MUST count measured `POST /json` requests only. `responses_completed_total` and response status bucket counters MUST count completed measured `POST /json` responses only. `/health`, `/runtime`, and rejected non-`POST /json` routes MUST NOT inflate measured request/response counters.

`active_requests` MUST count measured `POST /json` requests currently being processed. It SHOULD be decremented exactly once after a response is ready or the request fails.

`request_errors_total` MUST count server-side measured request failures such as invalid JSON, invalid shape, or response write failures when observable.

When `SERVER_EVENTS_PATH` is set, the server SHOULD write JSONL event records for unusual server-side errors. Request validation failures MAY be logged as events. The event schema is `schemas/server_events.schema.json`.

When `RUNTIME_METRICS_PATH` is set, the server SHOULD write runtime samples as JSONL at approximately one-second intervals. The runtime metrics schema is `schemas/runtime_metrics.schema.json`.

## Benchmark Fairness Rules

An implementation MUST do the same logical work as every other implementation:

- Accept the HTTP request.
- Read the full measured request body.
- Parse JSON using the language/runtime's normal JSON support or an equivalent standards-compliant parser.
- Validate the decoded request shape.
- Compute FNV-1a over the decoded payload's UTF-8 bytes.
- Serialize a JSON response for each successful request.

An implementation MUST NOT special-case the load generator by skipping JSON parsing, assuming a fixed byte layout, precomputing responses for benchmark payloads, hard-coding checksums, bypassing the configured endpoint, or replacing the HTTP server with a protocol-specific shortcut.

An implementation SHOULD avoid per-request diagnostic logging during measured traffic. Startup logs and low-rate error logs are acceptable.

Memory, allocator, runtime, and thread-pool tuning is allowed when it is representative, repeatable, and encoded in the implementation's manifest/runtime identity. OS-wide tuning belongs in the runner, not in individual implementations.

## Validation

Every implementation MUST pass:

```sh
./scripts/test-server-implementations.sh <server>
```

At minimum this starts the server on multiple local ports, validates the HTTP JSON contract with `scripts/check-http-json-server.mjs`, and runs a small fixed-work load-generator pass.

For a benchmark result to be considered accurate for comparison, the published `summary.json` SHOULD have:

- `complete: true`
- `success: true`
- `total_errors: 0`
- `total_sent == total_received`

`total_dispatch_misses` MAY be non-zero in open-loop mode. Dispatch misses are a saturation signal, not a contract failure, but they must be considered when comparing achieved throughput.

## Current Implementation Assessment

This assessment reflects the code and checked-in benchmark artifacts present when the contract was written.

| Implementation | Contract status | Benchmark accuracy assessment |
| --- | --- | --- |
| `servers/node` | Appropriate baseline. It supports the required endpoints, multi-port listening, keep-alive, safe integer ID validation, UTF-8 byte length, FNV-1a checksum, and activity/runtime metrics. Connection counters are intentionally `null` to avoid per-connection benchmark instrumentation overhead. | Benchmark artifacts were removed and should be regenerated. |
| `servers/bun` | Appropriate baseline. It supports the required endpoints, multi-port listening, keep-alive responses, safe integer ID validation, UTF-8 byte length, FNV-1a checksum, and activity/runtime metrics. Connection counters are intentionally `null` to match the other implementations. | Benchmark artifacts were removed and should be regenerated. |
| `servers/rust-hyper-tokio-st` | Appropriate baseline. It supports the required endpoints, multi-port listening, keep-alive, safe integer ID validation, UTF-8 byte length, FNV-1a checksum, and activity/runtime metrics. Connection counters are intentionally `null` to match the other implementations. | Benchmark artifacts were removed and should be regenerated. |
| `servers/rust-hyper-tokio-mt` | Appropriate multi-thread Rust variant. It has the same endpoint contract as `rust-hyper-tokio-st`, with Tokio's multi-thread runtime as the intentional runtime difference. Connection counters are intentionally `null` to match the other implementations. | Benchmark artifacts were removed and should be regenerated. |
