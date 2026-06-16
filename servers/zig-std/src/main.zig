const std = @import("std");

const max_safe_integer: u64 = 9007199254740991;
const Metrics = struct {
    active_requests: std.atomic.Value(u64) = .init(0),
    requests_started: std.atomic.Value(u64) = .init(0),
    responses_completed: std.atomic.Value(u64) = .init(0),
    responses_2xx: std.atomic.Value(u64) = .init(0),
    responses_4xx: std.atomic.Value(u64) = .init(0),
    responses_5xx: std.atomic.Value(u64) = .init(0),
    request_errors: std.atomic.Value(u64) = .init(0),
};

const JsonlWriter = struct {
    file: ?std.fs.File = null,
    mutex: std.Thread.Mutex = .{},

    fn open(path: ?[]const u8) !JsonlWriter {
        if (path == null or path.?.len == 0) return .{};
        return .{ .file = try std.fs.cwd().createFile(path.?, .{ .truncate = false }) };
    }

    fn write(self: *JsonlWriter, bytes: []const u8) void {
        if (self.file) |file| {
            self.mutex.lock();
            defer self.mutex.unlock();
            file.seekFromEnd(0) catch return;
            file.writeAll(bytes) catch return;
            file.writeAll("\n") catch return;
        }
    }

    fn close(self: *JsonlWriter) void {
        if (self.file) |file| file.close();
        self.file = null;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    started_ms: i64,
    metrics: Metrics = .{},
    events: JsonlWriter,
};

const RequestBody = struct {
    id: std.json.Value,
    payload: []const u8,
};

var stopping = std.atomic.Value(bool).init(false);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const host = std.process.getEnvVarOwned(allocator, "HOST") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "127.0.0.1"),
        else => return err,
    };
    defer allocator.free(host);

    const port_env = std.process.getEnvVarOwned(allocator, "PORTS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "PORT") catch |port_err| switch (port_err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, "8080"),
            else => return port_err,
        },
        else => return err,
    };
    defer allocator.free(port_env);

    const ports = try parsePorts(allocator, port_env);
    defer allocator.free(ports);

    var activity = try JsonlWriter.open(std.posix.getenv("ACTIVITY_METRICS_PATH"));
    defer activity.close();
    var runtime_metrics = try JsonlWriter.open(std.posix.getenv("RUNTIME_METRICS_PATH"));
    defer runtime_metrics.close();
    var state = State{
        .allocator = allocator,
        .started_ms = std.time.milliTimestamp(),
        .events = try JsonlWriter.open(std.posix.getenv("SERVER_EVENTS_PATH")),
    };
    defer state.events.close();

    const signal_action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &signal_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &signal_action, null);

    var listener_threads = try allocator.alloc(std.Thread, ports.len);
    defer allocator.free(listener_threads);
    for (ports, 0..) |port, index| {
        const args = ListenerArgs{ .host = host, .port = port, .state = &state };
        listener_threads[index] = try std.Thread.spawn(.{}, listenOnPort, .{args});
    }

    if (activity.file != null) writeActivity(&activity, &state);
    if (runtime_metrics.file != null) writeRuntime(&runtime_metrics, &state);

    while (!stopping.load(.monotonic)) {
        std.Thread.sleep(std.time.ns_per_s);
        if (activity.file != null) writeActivity(&activity, &state);
        if (runtime_metrics.file != null) writeRuntime(&runtime_metrics, &state);
    }

    // Closing listen sockets from another thread is not needed for benchmark shutdown; the harness sends SIGTERM.
}

const ListenerArgs = struct {
    host: []const u8,
    port: u16,
    state: *State,
};

fn listenOnPort(args: ListenerArgs) !void {
    const address = try std.net.Address.parseIp(args.host, args.port);
    var server = try address.listen(.{ .kernel_backlog = 65535, .reuse_address = true });
    defer server.deinit();
    std.debug.print("zig std.http JSON server listening on http://{s}:{d}\n", .{ args.host, args.port });

    while (!stopping.load(.monotonic)) {
        const connection = server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{ connection.stream, args.state }) catch {
            connection.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(stream: std.net.Stream, state: *State) !void {
    defer stream.close();
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    var writer = stream.writer(&write_buffer);
    var server = std.http.Server.init(reader.interface(), &writer.interface);

    while (!stopping.load(.monotonic)) {
        var request = server.receiveHead() catch return;
        handleRequest(&request, state) catch return;
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(request: *std.http.Server.Request, state: *State) !void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |index| target[0..index] else target;

    if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) {
        var buffer: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&buffer,
            "{{\"ok\":true,\"active_requests\":{d},\"requests_started_total\":{d},\"responses_completed_total\":{d},\"total_errors\":{d}}}",
            .{
                state.metrics.active_requests.load(.monotonic),
                state.metrics.requests_started.load(.monotonic),
                state.metrics.responses_completed.load(.monotonic),
                state.metrics.request_errors.load(.monotonic),
            },
        );
        return respond(request, .ok, body);
    }

    if (request.head.method == .GET and std.mem.eql(u8, path, "/runtime")) {
        var buffer: [256]u8 = undefined;
        const body = try runtimeJson(&buffer, state);
        return respond(request, .ok, body);
    }

    if (!(request.head.method == .POST and std.mem.eql(u8, path, "/json"))) {
        return respond(request, .not_found, "{\"error\":\"not_found\"}");
    }

    _ = state.metrics.active_requests.fetchAdd(1, .monotonic);
    _ = state.metrics.requests_started.fetchAdd(1, .monotonic);
    defer _ = state.metrics.active_requests.fetchSub(1, .monotonic);

    const body_reader = request.readerExpectContinue(&.{}) catch {
        return measuredError(request, state, "invalid_request");
    };
    const body_len: usize = @intCast(request.head.content_length orelse 16 * 1024);
    const body = body_reader.readAlloc(state.allocator, body_len) catch {
        return measuredError(request, state, "invalid_json");
    };
    defer state.allocator.free(body);

    const parsed = std.json.parseFromSlice(RequestBody, state.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return measuredError(request, state, "invalid_json");
    };
    defer parsed.deinit();

    const id = parseId(parsed.value.id) catch {
        return measuredError(request, state, "invalid_request");
    };
    const payload = parsed.value.payload;
    const sum = checksum(payload);

    recordResponse(&state.metrics, 200);
    var response_buffer: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buffer, "{{\"id\":{d},\"len\":{d},\"checksum\":{d}}}", .{ id, payload.len, sum });
    return respond(request, .ok, response);
}

fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = true,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn measuredError(request: *std.http.Server.Request, state: *State, reason: []const u8) !void {
    _ = state.metrics.request_errors.fetchAdd(1, .monotonic);
    recordResponse(&state.metrics, 400);
    writeEvent(&state.events, state, reason, 400);
    return respond(request, .bad_request, if (std.mem.eql(u8, reason, "invalid_json")) "{\"error\":\"invalid_json\"}" else "{\"error\":\"invalid_request\"}");
}

fn parseId(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| blk: {
            if (integer < 0) return error.InvalidID;
            const unsigned: u64 = @intCast(integer);
            if (unsigned > max_safe_integer) return error.InvalidID;
            break :blk unsigned;
        },
        else => error.InvalidID,
    };
}

fn checksum(payload: []const u8) u32 {
    var value: u32 = 2166136261;
    for (payload) |byte| {
        value ^= byte;
        value *%= 16777619;
    }
    return value;
}

fn recordResponse(metrics: *Metrics, status: u16) void {
    _ = metrics.responses_completed.fetchAdd(1, .monotonic);
    if (status >= 200 and status < 300) {
        _ = metrics.responses_2xx.fetchAdd(1, .monotonic);
    } else if (status >= 400 and status < 500) {
        _ = metrics.responses_4xx.fetchAdd(1, .monotonic);
    } else if (status >= 500) {
        _ = metrics.responses_5xx.fetchAdd(1, .monotonic);
    }
}

fn writeActivity(writer: *JsonlWriter, state: *State) void {
    var buffer: [768]u8 = undefined;
    var ts_buffer: [64]u8 = undefined;
    const ts = nowIso(&ts_buffer) catch "";
    const body = std.fmt.bufPrint(&buffer,
        "{{\"ts\":\"{s}\",\"elapsed_seconds\":{d},\"active_requests\":{d},\"requests_started_total\":{d},\"responses_completed_total\":{d},\"responses_2xx_total\":{d},\"responses_4xx_total\":{d},\"responses_5xx_total\":{d},\"request_errors_total\":{d}}}",
        .{
            ts,
            elapsedSeconds(state),
            state.metrics.active_requests.load(.monotonic),
            state.metrics.requests_started.load(.monotonic),
            state.metrics.responses_completed.load(.monotonic),
            state.metrics.responses_2xx.load(.monotonic),
            state.metrics.responses_4xx.load(.monotonic),
            state.metrics.responses_5xx.load(.monotonic),
            state.metrics.request_errors.load(.monotonic),
        },
    ) catch return;
    writer.write(body);
}

fn writeRuntime(writer: *JsonlWriter, state: *State) void {
    var buffer: [256]u8 = undefined;
    const body = runtimeJson(&buffer, state) catch return;
    writer.write(body);
}

fn runtimeJson(buffer: []u8, state: *State) ![]const u8 {
    var ts_buffer: [64]u8 = undefined;
    const ts = try nowIso(&ts_buffer);
    return std.fmt.bufPrint(buffer, "{{\"ts\":\"{s}\",\"elapsed_seconds\":{d},\"runtime\":\"zig-std\"}}", .{ ts, elapsedSeconds(state) });
}

fn writeEvent(writer: *JsonlWriter, state: *State, reason: []const u8, status: u16) void {
    var ts_buffer: [64]u8 = undefined;
    const ts = nowIso(&ts_buffer) catch "";
    var buffer: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "{{\"ts\":\"{s}\",\"elapsed_seconds\":{d},\"event\":\"request_error\",\"reason\":\"{s}\",\"status_code\":{d}}}", .{ ts, elapsedSeconds(state), reason, status }) catch return;
    writer.write(body);
}

fn nowIso(buffer: []u8) ![]const u8 {
    const seconds = std.time.timestamp();
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month) + 1,
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn elapsedSeconds(state: *State) i64 {
    return @divFloor(std.time.milliTimestamp() - state.started_ms, 1000);
}

fn parsePorts(allocator: std.mem.Allocator, value: []const u8) ![]u16 {
    var ports: std.ArrayList(u16) = .empty;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t\r\n");
        if (item.len == 0) continue;
        const parsed = try std.fmt.parseInt(u16, item, 10);
        if (parsed == 0) return error.InvalidPort;
        var seen = false;
        for (ports.items) |port| {
            if (port == parsed) seen = true;
        }
        if (!seen) try ports.append(allocator, parsed);
    }
    if (ports.items.len == 0) return error.InvalidPort;
    return ports.toOwnedSlice(allocator);
}

fn handleSignal(_: c_int) callconv(.c) void {
    stopping.store(true, .monotonic);
}
