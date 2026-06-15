#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <arpa/inet.h>
#include <inttypes.h>
#include <jansson.h>
#include <microhttpd.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_SAFE_INTEGER 9007199254740991ULL
#define MAX_BODY_BYTES (1024U * 1024U)

struct counters {
  volatile uint64_t active_requests;
  volatile uint64_t requests_started;
  volatile uint64_t responses_completed;
  volatile uint64_t responses_2xx;
  volatile uint64_t responses_4xx;
  volatile uint64_t responses_5xx;
  volatile uint64_t request_errors;
};

struct jsonl_writer {
  FILE *file;
};

struct app_state {
  struct counters counters;
  struct jsonl_writer activity;
  struct jsonl_writer events;
  struct jsonl_writer runtime;
  long long started_ms;
};

struct request_context {
  char *body;
  size_t body_len;
  bool measured;
};

static volatile sig_atomic_t stopping = 0;

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection,
                                      const char *url, const char *method,
                                      const char *version, const char *upload_data,
                                      size_t *upload_data_size, void **con_cls);
static enum MHD_Result send_json(struct MHD_Connection *connection, unsigned int status, const char *body);
static enum MHD_Result measured_error(struct app_state *state, struct MHD_Connection *connection, const char *reason);
static void request_completed(void *cls, struct MHD_Connection *connection, void **con_cls,
                              enum MHD_RequestTerminationCode toe);
static void record_response(struct counters *counters, unsigned int status);
static uint32_t checksum(const char *bytes, size_t len);
static bool parse_ports(const char *value, uint16_t **ports, size_t *count);
static char *first_nonempty(const char *a, const char *b, const char *fallback);
static long long now_ms(void);
static long long elapsed_seconds(const struct app_state *state);
static void now_iso(char *buffer, size_t len);
static void open_jsonl(struct jsonl_writer *writer, const char *path);
static void close_jsonl(struct jsonl_writer *writer);
static void write_jsonl(struct jsonl_writer *writer, const char *line);
static void write_activity(struct app_state *state);
static void write_runtime(struct app_state *state);
static void write_event(struct app_state *state, const char *reason, unsigned int status);
static void on_signal(int signal_number);

int main(void) {
  const char *host = getenv("HOST");
  if (!host || host[0] == '\0') host = "127.0.0.1";

  char *ports_value = first_nonempty(getenv("PORTS"), getenv("PORT"), "8080");
  uint16_t *ports = NULL;
  size_t port_count = 0;
  if (!parse_ports(ports_value, &ports, &port_count)) {
    fprintf(stderr, "c-libmicrohttpd: invalid PORTS\n");
    return 1;
  }

  struct app_state state = {0};
  state.started_ms = now_ms();
  open_jsonl(&state.activity, getenv("ACTIVITY_METRICS_PATH"));
  open_jsonl(&state.events, getenv("SERVER_EVENTS_PATH"));
  open_jsonl(&state.runtime, getenv("RUNTIME_METRICS_PATH"));

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  struct MHD_Daemon **daemons = calloc(port_count, sizeof(*daemons));
  if (!daemons) {
    perror("calloc");
    free(ports);
    return 1;
  }

  for (size_t i = 0; i < port_count; i++) {
    struct sockaddr_in bind_address;
    union MHD_DaemonInfo const *info = NULL;
    memset(&bind_address, 0, sizeof(bind_address));
    bind_address.sin_family = AF_INET;
    bind_address.sin_port = htons(ports[i]);
    if (inet_pton(AF_INET, host, &bind_address.sin_addr) != 1) {
      fprintf(stderr, "c-libmicrohttpd: HOST must be an IPv4 listen address: %s\n", host);
      stopping = 1;
      break;
    }
    daemons[i] = MHD_start_daemon(MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_THREAD_PER_CONNECTION,
                                  ports[i], NULL, NULL, handle_request, &state,
                                  MHD_OPTION_SOCK_ADDR, (struct sockaddr *)&bind_address,
                                  MHD_OPTION_NOTIFY_COMPLETED, request_completed, &state,
                                  MHD_OPTION_CONNECTION_TIMEOUT, (unsigned int)120,
                                  MHD_OPTION_END);
    if (!daemons[i]) {
      fprintf(stderr, "c-libmicrohttpd: failed to listen on %s:%u\n", host, ports[i]);
      stopping = 1;
      break;
    }
    info = MHD_get_daemon_info(daemons[i], MHD_DAEMON_INFO_BIND_PORT);
    (void)info;
    printf("C libmicrohttpd JSON server listening on http://%s:%u\n", host, ports[i]);
    fflush(stdout);
  }

  if (state.activity.file) write_activity(&state);
  if (state.runtime.file) write_runtime(&state);
  while (!stopping) {
    sleep(1);
    if (state.activity.file) write_activity(&state);
    if (state.runtime.file) write_runtime(&state);
  }

  for (size_t i = 0; i < port_count; i++) {
    if (daemons[i]) MHD_stop_daemon(daemons[i]);
  }
  free(daemons);
  free(ports);
  close_jsonl(&state.activity);
  close_jsonl(&state.events);
  close_jsonl(&state.runtime);
  return 0;
}

static enum MHD_Result handle_request(void *cls, struct MHD_Connection *connection,
                                      const char *url, const char *method,
                                      const char *version, const char *upload_data,
                                      size_t *upload_data_size, void **con_cls) {
  (void)version;
  struct app_state *state = cls;
  struct request_context *ctx = *con_cls;

  if (!ctx) {
    ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return MHD_NO;
    ctx->measured = strcmp(url, "/json") == 0 && strcmp(method, "POST") == 0;
    if (ctx->measured) {
      __sync_add_and_fetch(&state->counters.active_requests, 1);
      __sync_add_and_fetch(&state->counters.requests_started, 1);
    }
    *con_cls = ctx;
    return MHD_YES;
  }

  if (*upload_data_size > 0) {
    if (ctx->body_len + *upload_data_size > MAX_BODY_BYTES) {
      *upload_data_size = 0;
      return measured_error(state, connection, "invalid_request");
    }
    char *next = realloc(ctx->body, ctx->body_len + *upload_data_size + 1);
    if (!next) return MHD_NO;
    ctx->body = next;
    memcpy(ctx->body + ctx->body_len, upload_data, *upload_data_size);
    ctx->body_len += *upload_data_size;
    ctx->body[ctx->body_len] = '\0';
    *upload_data_size = 0;
    return MHD_YES;
  }

  if (strcmp(url, "/health") == 0 && strcmp(method, "GET") == 0) {
    char body[512];
    snprintf(body, sizeof(body),
             "{\"ok\":true,\"active_connections\":null,\"accepted_connections_total\":null,\"closed_connections_total\":null,\"active_requests\":%" PRIu64 ",\"requests_started_total\":%" PRIu64 ",\"responses_completed_total\":%" PRIu64 ",\"total_errors\":%" PRIu64 "}",
             state->counters.active_requests, state->counters.requests_started,
             state->counters.responses_completed, state->counters.request_errors);
    return send_json(connection, 200, body);
  }

  if (strcmp(url, "/runtime") == 0 && strcmp(method, "GET") == 0) {
    char ts[32];
    char body[192];
    now_iso(ts, sizeof(ts));
    snprintf(body, sizeof(body), "{\"ts\":\"%s\",\"elapsed_seconds\":%lld,\"runtime\":\"c-libmicrohttpd\"}",
             ts, elapsed_seconds(state));
    return send_json(connection, 200, body);
  }

  if (!ctx->measured) {
    return send_json(connection, 404, "{\"error\":\"not_found\"}");
  }

  json_error_t error;
  json_t *root = json_loadb(ctx->body ? ctx->body : "", ctx->body_len, JSON_DECODE_ANY, &error);
  if (!root) return measured_error(state, connection, "invalid_json");
  if (!json_is_object(root)) {
    json_decref(root);
    return measured_error(state, connection, "invalid_request");
  }

  json_t *id_value = json_object_get(root, "id");
  json_t *payload_value = json_object_get(root, "payload");
  if (!json_is_integer(id_value) || !json_is_string(payload_value)) {
    json_decref(root);
    return measured_error(state, connection, "invalid_request");
  }

  json_int_t id = json_integer_value(id_value);
  if (id < 0 || (uint64_t)id > MAX_SAFE_INTEGER) {
    json_decref(root);
    return measured_error(state, connection, "invalid_request");
  }

  const char *payload = json_string_value(payload_value);
  size_t payload_len = json_string_length(payload_value);
  uint32_t sum = checksum(payload, payload_len);
  char body[256];
  snprintf(body, sizeof(body), "{\"id\":%" PRId64 ",\"len\":%zu,\"checksum\":%" PRIu32 "}",
           (int64_t)id, payload_len, sum);
  json_decref(root);
  record_response(&state->counters, 200);
  return send_json(connection, 200, body);
}

static enum MHD_Result send_json(struct MHD_Connection *connection, unsigned int status, const char *body) {
  struct MHD_Response *response = MHD_create_response_from_buffer(strlen(body), (void *)body, MHD_RESPMEM_MUST_COPY);
  if (!response) return MHD_NO;
  MHD_add_response_header(response, MHD_HTTP_HEADER_CONTENT_TYPE, "application/json");
  MHD_add_response_header(response, MHD_HTTP_HEADER_CONNECTION, "keep-alive");
  enum MHD_Result result = MHD_queue_response(connection, status, response);
  MHD_destroy_response(response);
  return result;
}

static enum MHD_Result measured_error(struct app_state *state, struct MHD_Connection *connection, const char *reason) {
  __sync_add_and_fetch(&state->counters.request_errors, 1);
  record_response(&state->counters, 400);
  write_event(state, reason, 400);
  if (strcmp(reason, "invalid_json") == 0) {
    return send_json(connection, 400, "{\"error\":\"invalid_json\"}");
  }
  return send_json(connection, 400, "{\"error\":\"invalid_request\"}");
}

static void request_completed(void *cls, struct MHD_Connection *connection, void **con_cls,
                              enum MHD_RequestTerminationCode toe) {
  (void)connection;
  (void)toe;
  struct app_state *state = cls;
  struct request_context *ctx = *con_cls;
  if (!ctx) return;
  if (ctx->measured) __sync_sub_and_fetch(&state->counters.active_requests, 1);
  free(ctx->body);
  free(ctx);
  *con_cls = NULL;
}

static void record_response(struct counters *counters, unsigned int status) {
  __sync_add_and_fetch(&counters->responses_completed, 1);
  if (status >= 200 && status < 300) {
    __sync_add_and_fetch(&counters->responses_2xx, 1);
  } else if (status >= 400 && status < 500) {
    __sync_add_and_fetch(&counters->responses_4xx, 1);
  } else if (status >= 500) {
    __sync_add_and_fetch(&counters->responses_5xx, 1);
  }
}

static uint32_t checksum(const char *bytes, size_t len) {
  uint32_t value = 2166136261U;
  for (size_t i = 0; i < len; i++) {
    value ^= (unsigned char)bytes[i];
    value *= 16777619U;
  }
  return value;
}

static bool parse_ports(const char *value, uint16_t **ports, size_t *count) {
  char *copy = strdup(value ? value : "8080");
  if (!copy) return false;
  size_t capacity = 4;
  *ports = calloc(capacity, sizeof(**ports));
  *count = 0;
  if (!*ports) {
    free(copy);
    return false;
  }
  for (char *part = strtok(copy, ","); part; part = strtok(NULL, ",")) {
    while (*part == ' ' || *part == '\t') part++;
    char *end = NULL;
    errno = 0;
    long port = strtol(part, &end, 10);
    if (errno || end == part || port <= 0 || port >= 65536) {
      free(copy);
      return false;
    }
    bool seen = false;
    for (size_t i = 0; i < *count; i++) {
      if ((*ports)[i] == (uint16_t)port) seen = true;
    }
    if (seen) continue;
    if (*count == capacity) {
      capacity *= 2;
      uint16_t *next = realloc(*ports, capacity * sizeof(**ports));
      if (!next) {
        free(copy);
        return false;
      }
      *ports = next;
    }
    (*ports)[(*count)++] = (uint16_t)port;
  }
  free(copy);
  return *count > 0;
}

static char *first_nonempty(const char *a, const char *b, const char *fallback) {
  if (a && a[0] != '\0') return (char *)a;
  if (b && b[0] != '\0') return (char *)b;
  return (char *)fallback;
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return ((long long)ts.tv_sec * 1000LL) + (ts.tv_nsec / 1000000LL);
}

static long long elapsed_seconds(const struct app_state *state) {
  return (now_ms() - state->started_ms) / 1000LL;
}

static void now_iso(char *buffer, size_t len) {
  time_t now = time(NULL);
  struct tm tm;
  gmtime_r(&now, &tm);
  strftime(buffer, len, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static void open_jsonl(struct jsonl_writer *writer, const char *path) {
  writer->file = NULL;
  if (!path || path[0] == '\0') return;
  writer->file = fopen(path, "a");
  if (!writer->file) {
    perror(path);
    exit(1);
  }
}

static void close_jsonl(struct jsonl_writer *writer) {
  if (writer->file) fclose(writer->file);
  writer->file = NULL;
}

static void write_jsonl(struct jsonl_writer *writer, const char *line) {
  if (!writer->file) return;
  fputs(line, writer->file);
  fputc('\n', writer->file);
  fflush(writer->file);
}

static void write_activity(struct app_state *state) {
  char ts[32];
  char line[768];
  now_iso(ts, sizeof(ts));
  snprintf(line, sizeof(line),
           "{\"ts\":\"%s\",\"elapsed_seconds\":%lld,\"active_connections\":null,\"accepted_connections_total\":null,\"closed_connections_total\":null,\"active_requests\":%" PRIu64 ",\"requests_started_total\":%" PRIu64 ",\"responses_completed_total\":%" PRIu64 ",\"responses_2xx_total\":%" PRIu64 ",\"responses_4xx_total\":%" PRIu64 ",\"responses_5xx_total\":%" PRIu64 ",\"request_errors_total\":%" PRIu64 "}",
           ts, elapsed_seconds(state), state->counters.active_requests, state->counters.requests_started,
           state->counters.responses_completed, state->counters.responses_2xx, state->counters.responses_4xx,
           state->counters.responses_5xx, state->counters.request_errors);
  write_jsonl(&state->activity, line);
}

static void write_runtime(struct app_state *state) {
  char ts[32];
  char line[192];
  now_iso(ts, sizeof(ts));
  snprintf(line, sizeof(line), "{\"ts\":\"%s\",\"elapsed_seconds\":%lld,\"runtime\":\"c-libmicrohttpd\"}",
           ts, elapsed_seconds(state));
  write_jsonl(&state->runtime, line);
}

static void write_event(struct app_state *state, const char *reason, unsigned int status) {
  char ts[32];
  char line[256];
  now_iso(ts, sizeof(ts));
  snprintf(line, sizeof(line), "{\"ts\":\"%s\",\"elapsed_seconds\":%lld,\"event\":\"request_error\",\"reason\":\"%s\",\"status_code\":%u}",
           ts, elapsed_seconds(state), reason, status);
  write_jsonl(&state->events, line);
}

static void on_signal(int signal_number) {
  (void)signal_number;
  stopping = 1;
}
