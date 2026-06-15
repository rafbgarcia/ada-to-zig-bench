using System.Buffers;
using System.Diagnostics;
using System.Text.Json;
using System.Threading;

const long MaxSafeInteger = 9007199254740991L;

var host = Environment.GetEnvironmentVariable("HOST");
if (string.IsNullOrWhiteSpace(host)) host = "127.0.0.1";
var ports = ParsePorts(Environment.GetEnvironmentVariable("PORTS") ?? Environment.GetEnvironmentVariable("PORT") ?? "8080");
var urls = ports.Select(port => $"http://{host}:{port}").ToArray();

var started = Stopwatch.StartNew();
var counters = new Counters();
using var activity = JsonlWriter.Open(Environment.GetEnvironmentVariable("ACTIVITY_METRICS_PATH"));
using var events = JsonlWriter.Open(Environment.GetEnvironmentVariable("SERVER_EVENTS_PATH"));
using var runtime = JsonlWriter.Open(Environment.GetEnvironmentVariable("RUNTIME_METRICS_PATH"));

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(urls);
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(120);
    options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);
});

var app = builder.Build();

app.MapGet("/health", () => JsonResponse(new Dictionary<string, object?>
{
    ["ok"] = true,
    ["active_connections"] = null,
    ["accepted_connections_total"] = null,
    ["closed_connections_total"] = null,
    ["active_requests"] = Interlocked.Read(ref counters.ActiveRequests),
    ["requests_started_total"] = Interlocked.Read(ref counters.RequestsStarted),
    ["responses_completed_total"] = Interlocked.Read(ref counters.ResponsesCompleted),
    ["total_errors"] = Interlocked.Read(ref counters.RequestErrors),
}));

app.MapGet("/runtime", () => JsonResponse(RuntimeSample(started)));

app.MapPost("/json", async (HttpContext context) =>
{
    Interlocked.Increment(ref counters.ActiveRequests);
    Interlocked.Increment(ref counters.RequestsStarted);
    try
    {
        JsonDocument document;
        try
        {
            document = await JsonDocument.ParseAsync(context.Request.Body);
        }
        catch (JsonException)
        {
            return MeasuredError(counters, events, started, "invalid_json");
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("id", out var idElement) ||
                !document.RootElement.TryGetProperty("payload", out var payloadElement) ||
                idElement.ValueKind != JsonValueKind.Number ||
                payloadElement.ValueKind != JsonValueKind.String ||
                !idElement.TryGetInt64(out var id) ||
                id < 0 || id > MaxSafeInteger)
            {
                return MeasuredError(counters, events, started, "invalid_request");
            }

            var payload = payloadElement.GetString();
            if (payload is null)
            {
                return MeasuredError(counters, events, started, "invalid_request");
            }

            var byteCount = System.Text.Encoding.UTF8.GetByteCount(payload);
            var rented = ArrayPool<byte>.Shared.Rent(byteCount);
            try
            {
                var written = System.Text.Encoding.UTF8.GetBytes(payload, rented);
                RecordResponse(counters, 200);
                return JsonResponse(new { id, len = written, checksum = Checksum(rented.AsSpan(0, written)) });
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }
    finally
    {
        Interlocked.Decrement(ref counters.ActiveRequests);
    }
});

app.MapFallback(() => JsonResponse(new { error = "not_found" }, statusCode: 404));

foreach (var url in urls) Console.WriteLine($"C# ASP.NET Core JSON server listening on {url}");

using var activityTimer = activity.Enabled ? new Timer(_ => activity.Write(ActivitySample(counters, started)), null, TimeSpan.Zero, TimeSpan.FromSeconds(1)) : null;
using var runtimeTimer = runtime.Enabled ? new Timer(_ => runtime.Write(RuntimeSample(started)), null, TimeSpan.Zero, TimeSpan.FromSeconds(1)) : null;

await app.RunAsync();

static IResult MeasuredError(Counters counters, JsonlWriter events, Stopwatch started, string reason)
{
    Interlocked.Increment(ref counters.RequestErrors);
    RecordResponse(counters, 400);
    events.Write(new Dictionary<string, object?>
    {
        ["ts"] = DateTimeOffset.UtcNow.ToString("O"),
        ["elapsed_seconds"] = (long)started.Elapsed.TotalSeconds,
        ["event"] = "request_error",
        ["reason"] = reason,
        ["status_code"] = 400,
    });
    return JsonResponse(new { error = reason }, statusCode: 400);
}

static IResult JsonResponse(object value, int statusCode = 200) => new FixedLengthJsonResult(value, statusCode);

static void RecordResponse(Counters counters, int status)
{
    Interlocked.Increment(ref counters.ResponsesCompleted);
    if (status >= 200 && status < 300) Interlocked.Increment(ref counters.Responses2xx);
    else if (status >= 400 && status < 500) Interlocked.Increment(ref counters.Responses4xx);
    else if (status >= 500) Interlocked.Increment(ref counters.Responses5xx);
}

static uint Checksum(ReadOnlySpan<byte> payload)
{
    uint value = 2166136261U;
    foreach (var b in payload)
    {
        value ^= b;
        value *= 16777619U;
    }
    return value;
}

static Dictionary<string, object?> ActivitySample(Counters counters, Stopwatch started) => new()
{
    ["ts"] = DateTimeOffset.UtcNow.ToString("O"),
    ["elapsed_seconds"] = (long)started.Elapsed.TotalSeconds,
    ["active_connections"] = null,
    ["accepted_connections_total"] = null,
    ["closed_connections_total"] = null,
    ["active_requests"] = Interlocked.Read(ref counters.ActiveRequests),
    ["requests_started_total"] = Interlocked.Read(ref counters.RequestsStarted),
    ["responses_completed_total"] = Interlocked.Read(ref counters.ResponsesCompleted),
    ["responses_2xx_total"] = Interlocked.Read(ref counters.Responses2xx),
    ["responses_4xx_total"] = Interlocked.Read(ref counters.Responses4xx),
    ["responses_5xx_total"] = Interlocked.Read(ref counters.Responses5xx),
    ["request_errors_total"] = Interlocked.Read(ref counters.RequestErrors),
};

static Dictionary<string, object?> RuntimeSample(Stopwatch started)
{
    var gc = GC.GetGCMemoryInfo();
    return new Dictionary<string, object?>
    {
        ["ts"] = DateTimeOffset.UtcNow.ToString("O"),
        ["elapsed_seconds"] = (long)started.Elapsed.TotalSeconds,
        ["runtime"] = "csharp-aspnetcore",
        ["heap_used_bytes"] = GC.GetTotalMemory(false),
        ["heap_total_bytes"] = gc.HeapSizeBytes,
        ["gc_committed_bytes"] = gc.TotalCommittedBytes,
    };
}

static List<int> ParsePorts(string value)
{
    var ports = new List<int>();
    var seen = new HashSet<int>();
    foreach (var item in value.Split(','))
    {
        var trimmed = item.Trim();
        if (trimmed.Length == 0) continue;
        if (!int.TryParse(trimmed, out var port) || port <= 0 || port >= 65536) throw new ArgumentException($"invalid port: {trimmed}");
        if (seen.Add(port)) ports.Add(port);
    }
    if (ports.Count == 0) throw new ArgumentException("PORTS must contain at least one TCP port");
    return ports;
}

sealed class Counters
{
    public long ActiveRequests;
    public long RequestsStarted;
    public long ResponsesCompleted;
    public long Responses2xx;
    public long Responses4xx;
    public long Responses5xx;
    public long RequestErrors;
}

sealed class JsonlWriter : IDisposable
{
    private readonly StreamWriter? writer;
    private readonly object gate = new();

    private JsonlWriter(StreamWriter? writer) => this.writer = writer;
    public bool Enabled => writer is not null;

    public static JsonlWriter Open(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return new JsonlWriter(null);
        return new JsonlWriter(new StreamWriter(File.Open(path, FileMode.Append, FileAccess.Write, FileShare.Read)) { AutoFlush = true });
    }

    public void Write(object value)
    {
        if (writer is null) return;
        lock (gate) writer.WriteLine(JsonSerializer.Serialize(value));
    }

    public void Dispose() => writer?.Dispose();
}

sealed class FixedLengthJsonResult : IResult
{
    private readonly object value;
    private readonly int statusCode;

    public FixedLengthJsonResult(object value, int statusCode)
    {
        this.value = value;
        this.statusCode = statusCode;
    }

    public async Task ExecuteAsync(HttpContext context)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(value);
        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength = body.Length;
        context.Response.Headers.Connection = "keep-alive";
        await context.Response.Body.WriteAsync(body);
    }
}
