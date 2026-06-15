import asyncio
import gc
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

from aiohttp import web


MAX_SAFE_INTEGER = 9007199254740991
STARTED_AT = time.monotonic()


class Counters:
    def __init__(self):
        self.active_requests = 0
        self.requests_started = 0
        self.responses_completed = 0
        self.responses_2xx = 0
        self.responses_4xx = 0
        self.responses_5xx = 0
        self.request_errors = 0

    def record_response(self, status):
        self.responses_completed += 1
        if 200 <= status < 300:
            self.responses_2xx += 1
        elif 400 <= status < 500:
            self.responses_4xx += 1
        elif status >= 500:
            self.responses_5xx += 1


class JsonlWriter:
    def __init__(self, path):
        self.file = open(path, "a", encoding="utf-8") if path else None

    def write(self, value):
        if self.file is None:
            return
        self.file.write(json.dumps(value, separators=(",", ":")) + "\n")
        self.file.flush()

    def close(self):
        if self.file is not None:
            self.file.close()


def main():
    try:
        ports = parse_ports(os.environ.get("PORTS") or os.environ.get("PORT") or "8080")
    except ValueError as exc:
        print(f"python-aiohttp: {exc}", file=sys.stderr)
        sys.exit(1)

    host = os.environ.get("HOST") or "127.0.0.1"
    asyncio.run(run(host, ports))


async def run(host, ports):
    counters = Counters()
    activity = JsonlWriter(os.environ.get("ACTIVITY_METRICS_PATH"))
    events = JsonlWriter(os.environ.get("SERVER_EVENTS_PATH"))
    runtime = JsonlWriter(os.environ.get("RUNTIME_METRICS_PATH"))

    app = web.Application()
    app["counters"] = counters
    app["events"] = events
    app.router.add_get("/health", health)
    app.router.add_get("/runtime", runtime_endpoint)
    app.router.add_post("/json", json_endpoint)
    app.router.add_route("*", "/{tail:.*}", not_found)

    runner = web.AppRunner(app, access_log=None, keepalive_timeout=120)
    await runner.setup()
    sites = [web.TCPSite(runner, host, port, backlog=65535) for port in ports]
    for site, port in zip(sites, ports):
        await site.start()
        print(f"python aiohttp JSON server listening on http://{host}:{port}", flush=True)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signame in ("SIGINT", "SIGTERM"):
        signum = getattr(signal, signame, None)
        if signum is None:
            continue
        try:
            loop.add_signal_handler(signum, stop.set)
        except NotImplementedError:
            pass

    tasks = []
    if activity.file is not None:
        activity.write(activity_sample(counters))
        tasks.append(asyncio.create_task(sample_every(activity, lambda: activity_sample(counters))))
    if runtime.file is not None:
        runtime.write(runtime_sample())
        tasks.append(asyncio.create_task(sample_every(runtime, runtime_sample)))

    try:
        await stop.wait()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await runner.cleanup()
        activity.close()
        events.close()
        runtime.close()


async def health(request):
    counters = request.app["counters"]
    return json_response({
        "ok": True,
        "active_connections": None,
        "accepted_connections_total": None,
        "closed_connections_total": None,
        "active_requests": counters.active_requests,
        "requests_started_total": counters.requests_started,
        "responses_completed_total": counters.responses_completed,
        "total_errors": counters.request_errors,
    })


async def runtime_endpoint(request):
    return json_response(runtime_sample())


async def not_found(request):
    return json_response({"error": "not_found"}, status=404)


async def json_endpoint(request):
    counters = request.app["counters"]
    counters.active_requests += 1
    counters.requests_started += 1
    try:
        try:
            body = await request.text()
            data = json.loads(body)
        except Exception:
            return measured_error(request, "invalid_json")

        if not isinstance(data, dict):
            return measured_error(request, "invalid_request")
        request_id = data.get("id")
        payload = data.get("payload")
        if not valid_id(request_id) or not isinstance(payload, str):
            return measured_error(request, "invalid_request")

        payload_bytes = payload.encode("utf-8")
        counters.record_response(200)
        return json_response({
            "id": request_id,
            "len": len(payload_bytes),
            "checksum": checksum(payload_bytes),
        })
    finally:
        counters.active_requests -= 1


def measured_error(request, reason):
    counters = request.app["counters"]
    counters.request_errors += 1
    counters.record_response(400)
    write_event(request.app["events"], "request_error", {"reason": reason, "status_code": 400})
    return json_response({"error": reason}, status=400)


def valid_id(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= MAX_SAFE_INTEGER


def json_response(value, status=200):
    body = json.dumps(value, separators=(",", ":")).encode("utf-8")
    return web.Response(
        body=body,
        status=status,
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
            "Connection": "keep-alive",
        },
    )


def checksum(payload):
    value = 2166136261
    for byte in payload:
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value


def activity_sample(counters):
    return {
        "ts": now_iso(),
        "elapsed_seconds": elapsed_seconds(),
        "active_connections": None,
        "accepted_connections_total": None,
        "closed_connections_total": None,
        "active_requests": counters.active_requests,
        "requests_started_total": counters.requests_started,
        "responses_completed_total": counters.responses_completed,
        "responses_2xx_total": counters.responses_2xx,
        "responses_4xx_total": counters.responses_4xx,
        "responses_5xx_total": counters.responses_5xx,
        "request_errors_total": counters.request_errors,
    }


def runtime_sample():
    sample = {
        "ts": now_iso(),
        "elapsed_seconds": elapsed_seconds(),
        "runtime": "python-aiohttp",
        "gc_counts": list(gc.get_count()),
    }
    if hasattr(sys, "getallocatedblocks"):
        sample["allocated_blocks"] = sys.getallocatedblocks()
    return sample


def write_event(writer, event, fields):
    value = {"ts": now_iso(), "elapsed_seconds": elapsed_seconds(), "event": event}
    value.update(fields)
    writer.write(value)


async def sample_every(writer, fn):
    while True:
        await asyncio.sleep(1)
        writer.write(fn())


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def elapsed_seconds():
    return int(time.monotonic() - STARTED_AT)


def parse_ports(value):
    ports = []
    seen = set()
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            port = int(item, 10)
        except ValueError as exc:
            raise ValueError(f"invalid port {item!r}") from exc
        if port <= 0 or port >= 65536:
            raise ValueError(f"invalid port {item!r}")
        if port not in seen:
            seen.add(port)
            ports.append(port)
    if not ports:
        raise ValueError("PORTS must contain at least one TCP port")
    return ports


if __name__ == "__main__":
    main()
