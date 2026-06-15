import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParseException;
import com.google.gson.JsonParser;
import com.google.gson.JsonPrimitive;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryUsage;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

public final class Server {
    private static final long MAX_SAFE_INTEGER = 9_007_199_254_740_991L;
    private static final Instant STARTED_AT = Instant.now();
    private static final Gson GSON = new GsonBuilder().serializeNulls().create();

    public static void main(String[] args) throws Exception {
        String host = firstNonEmpty(System.getenv("HOST"), "127.0.0.1");
        List<Integer> ports = parsePorts(firstNonEmpty(System.getenv("PORTS"), System.getenv("PORT"), "8080"));

        Counters counters = new Counters();
        JsonlWriter activity = JsonlWriter.open(System.getenv("ACTIVITY_METRICS_PATH"));
        JsonlWriter events = JsonlWriter.open(System.getenv("SERVER_EVENTS_PATH"));
        JsonlWriter runtime = JsonlWriter.open(System.getenv("RUNTIME_METRICS_PATH"));
        State state = new State(counters, events);

        List<HttpServer> servers = new ArrayList<>();
        for (int port : ports) {
            HttpServer server = HttpServer.create(new InetSocketAddress(host, port), 65_535);
            server.createContext("/", new Handler(state));
            server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
            server.start();
            servers.add(server);
            System.out.printf("java HttpServer JSON server listening on http://%s:%d%n", host, port);
        }

        ScheduledExecutorService sampler = Executors.newScheduledThreadPool(2);
        if (activity.enabled()) {
            activity.write(activitySample(counters));
            sampler.scheduleAtFixedRate(() -> activity.write(activitySample(counters)), 1, 1, TimeUnit.SECONDS);
        }
        if (runtime.enabled()) {
            runtime.write(runtimeSample());
            sampler.scheduleAtFixedRate(() -> runtime.write(runtimeSample()), 1, 1, TimeUnit.SECONDS);
        }

        CountDownLatch stopped = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            sampler.shutdownNow();
            for (HttpServer server : servers) {
                server.stop(0);
            }
            activity.close();
            events.close();
            runtime.close();
            stopped.countDown();
        }));
        stopped.await();
    }

    private static final class Handler implements HttpHandler {
        private final State state;

        private Handler(State state) {
            this.state = state;
        }

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String method = exchange.getRequestMethod();

            if (path.equals("/health") && method.equals("GET")) {
                writeJson(exchange, 200, healthSample(state.counters));
                return;
            }
            if (path.equals("/runtime") && method.equals("GET")) {
                writeJson(exchange, 200, runtimeSample());
                return;
            }
            if (!path.equals("/json") || !method.equals("POST")) {
                writeJson(exchange, 404, Map.of("error", "not_found"));
                return;
            }

            state.counters.activeRequests.incrementAndGet();
            state.counters.requestsStarted.incrementAndGet();
            try {
                byte[] bytes = exchange.getRequestBody().readAllBytes();
                JsonObject request;
                try {
                    JsonElement parsed = JsonParser.parseString(new String(bytes, StandardCharsets.UTF_8));
                    if (!parsed.isJsonObject()) {
                        measuredError(exchange, state, "invalid_request");
                        return;
                    }
                    request = parsed.getAsJsonObject();
                } catch (JsonParseException | IllegalStateException error) {
                    measuredError(exchange, state, "invalid_json");
                    return;
                }

                Long id = parseId(request.get("id"));
                String payload = parsePayload(request.get("payload"));
                if (id == null || payload == null) {
                    measuredError(exchange, state, "invalid_request");
                    return;
                }

                byte[] payloadBytes = payload.getBytes(StandardCharsets.UTF_8);
                state.counters.recordResponse(200);
                Map<String, Object> response = new LinkedHashMap<>();
                response.put("id", id);
                response.put("len", payloadBytes.length);
                response.put("checksum", checksum(payloadBytes));
                writeJson(exchange, 200, response);
            } finally {
                state.counters.activeRequests.decrementAndGet();
            }
        }
    }

    private static Long parseId(JsonElement element) {
        if (element == null || !element.isJsonPrimitive()) {
            return null;
        }
        JsonPrimitive primitive = element.getAsJsonPrimitive();
        if (!primitive.isNumber()) {
            return null;
        }
        try {
            BigDecimal decimal = primitive.getAsBigDecimal();
            BigInteger integer = decimal.toBigIntegerExact();
            if (integer.signum() < 0 || integer.compareTo(BigInteger.valueOf(MAX_SAFE_INTEGER)) > 0) {
                return null;
            }
            return integer.longValueExact();
        } catch (ArithmeticException | NumberFormatException error) {
            return null;
        }
    }

    private static String parsePayload(JsonElement element) {
        if (element == null || !element.isJsonPrimitive()) {
            return null;
        }
        JsonPrimitive primitive = element.getAsJsonPrimitive();
        return primitive.isString() ? primitive.getAsString() : null;
    }

    private static void measuredError(HttpExchange exchange, State state, String reason) throws IOException {
        state.counters.requestErrors.incrementAndGet();
        state.counters.recordResponse(400);
        writeEvent(state.events, "request_error", Map.of("reason", reason, "status_code", 400));
        writeJson(exchange, 400, Map.of("error", reason));
    }

    private static void writeJson(HttpExchange exchange, int status, Object value) throws IOException {
        byte[] body = GSON.toJson(value).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("Content-Length", Integer.toString(body.length));
        exchange.getResponseHeaders().set("Connection", "keep-alive");
        exchange.sendResponseHeaders(status, body.length);
        try (OutputStream output = exchange.getResponseBody()) {
            output.write(body);
        }
    }

    private static long checksum(byte[] payload) {
        int value = 0x811c9dc5;
        for (byte b : payload) {
            value ^= b & 0xff;
            value *= 0x01000193;
        }
        return Integer.toUnsignedLong(value);
    }

    private static Map<String, Object> healthSample(Counters counters) {
        Map<String, Object> sample = new LinkedHashMap<>();
        sample.put("ok", true);
        sample.put("active_connections", null);
        sample.put("accepted_connections_total", null);
        sample.put("closed_connections_total", null);
        sample.put("active_requests", counters.activeRequests.get());
        sample.put("requests_started_total", counters.requestsStarted.get());
        sample.put("responses_completed_total", counters.responsesCompleted.get());
        sample.put("total_errors", counters.requestErrors.get());
        return sample;
    }

    private static Map<String, Object> activitySample(Counters counters) {
        Map<String, Object> sample = new LinkedHashMap<>();
        sample.put("ts", nowIso());
        sample.put("elapsed_seconds", elapsedSeconds());
        sample.put("active_connections", null);
        sample.put("accepted_connections_total", null);
        sample.put("closed_connections_total", null);
        sample.put("active_requests", counters.activeRequests.get());
        sample.put("requests_started_total", counters.requestsStarted.get());
        sample.put("responses_completed_total", counters.responsesCompleted.get());
        sample.put("responses_2xx_total", counters.responses2xx.get());
        sample.put("responses_4xx_total", counters.responses4xx.get());
        sample.put("responses_5xx_total", counters.responses5xx.get());
        sample.put("request_errors_total", counters.requestErrors.get());
        return sample;
    }

    private static Map<String, Object> runtimeSample() {
        MemoryMXBean memory = ManagementFactory.getMemoryMXBean();
        MemoryUsage heap = memory.getHeapMemoryUsage();
        Runtime runtime = Runtime.getRuntime();
        Map<String, Object> sample = new LinkedHashMap<>();
        sample.put("ts", nowIso());
        sample.put("elapsed_seconds", elapsedSeconds());
        sample.put("runtime", "java-httpserver");
        sample.put("heap_total_bytes", heap.getCommitted());
        sample.put("heap_used_bytes", heap.getUsed());
        sample.put("heap_size_limit_bytes", heap.getMax());
        sample.put("total_memory_bytes", runtime.totalMemory());
        sample.put("free_memory_bytes", runtime.freeMemory());
        return sample;
    }

    private static void writeEvent(JsonlWriter writer, String event, Map<String, Object> fields) {
        if (!writer.enabled()) {
            return;
        }
        Map<String, Object> sample = new LinkedHashMap<>();
        sample.put("ts", nowIso());
        sample.put("elapsed_seconds", elapsedSeconds());
        sample.put("event", event);
        sample.putAll(fields);
        writer.write(sample);
    }

    private static String nowIso() {
        return Instant.now().toString();
    }

    private static long elapsedSeconds() {
        return Duration.between(STARTED_AT, Instant.now()).toSeconds();
    }

    private static String firstNonEmpty(String... values) {
        for (String value : values) {
            if (value != null && !value.isEmpty()) {
                return value;
            }
        }
        return "";
    }

    private static List<Integer> parsePorts(String value) {
        Set<Integer> seen = new TreeSet<>();
        List<Integer> ports = new ArrayList<>();
        for (String item : value.split(",")) {
            String trimmed = item.trim();
            if (trimmed.isEmpty()) {
                continue;
            }
            int port;
            try {
                port = Integer.parseInt(trimmed);
            } catch (NumberFormatException error) {
                throw new IllegalArgumentException("invalid port: " + trimmed);
            }
            if (port <= 0 || port >= 65_536) {
                throw new IllegalArgumentException("invalid port: " + trimmed);
            }
            if (seen.add(port)) {
                ports.add(port);
            }
        }
        if (ports.isEmpty()) {
            throw new IllegalArgumentException("PORTS must contain at least one TCP port");
        }
        return ports;
    }

    private record State(Counters counters, JsonlWriter events) {}

    private static final class Counters {
        private final AtomicLong activeRequests = new AtomicLong();
        private final AtomicLong requestsStarted = new AtomicLong();
        private final AtomicLong responsesCompleted = new AtomicLong();
        private final AtomicLong responses2xx = new AtomicLong();
        private final AtomicLong responses4xx = new AtomicLong();
        private final AtomicLong responses5xx = new AtomicLong();
        private final AtomicLong requestErrors = new AtomicLong();

        private void recordResponse(int status) {
            responsesCompleted.incrementAndGet();
            if (status >= 200 && status < 300) {
                responses2xx.incrementAndGet();
            } else if (status >= 400 && status < 500) {
                responses4xx.incrementAndGet();
            } else if (status >= 500) {
                responses5xx.incrementAndGet();
            }
        }
    }

    private static final class JsonlWriter implements AutoCloseable {
        private final BufferedWriter writer;

        private JsonlWriter(BufferedWriter writer) {
            this.writer = writer;
        }

        private static JsonlWriter open(String path) throws IOException {
            if (path == null || path.isEmpty()) {
                return new JsonlWriter(null);
            }
            return new JsonlWriter(Files.newBufferedWriter(Path.of(path), StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND, StandardOpenOption.WRITE));
        }

        private boolean enabled() {
            return writer != null;
        }

        private synchronized void write(Object value) {
            if (writer == null) {
                return;
            }
            try {
                writer.write(GSON.toJson(value));
                writer.newLine();
                writer.flush();
            } catch (IOException error) {
                System.err.printf("java-httpserver: metrics write failed: %s%n", error.getMessage());
            }
        }

        @Override
        public synchronized void close() {
            if (writer == null) {
                return;
            }
            try {
                writer.close();
            } catch (IOException ignored) {
            }
        }
    }
}
