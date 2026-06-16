#include <boost/asio.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
using tcp = asio::ip::tcp;
using json = nlohmann::json;

constexpr std::uint64_t max_safe_integer = 9007199254740991ULL;
const auto started_at = std::chrono::steady_clock::now();
std::atomic_bool stopping{false};

struct Counters {
  std::atomic<std::uint64_t> active_requests{0};
  std::atomic<std::uint64_t> requests_started{0};
  std::atomic<std::uint64_t> responses_completed{0};
  std::atomic<std::uint64_t> responses_2xx{0};
  std::atomic<std::uint64_t> responses_4xx{0};
  std::atomic<std::uint64_t> responses_5xx{0};
  std::atomic<std::uint64_t> request_errors{0};
};

class JsonlWriter {
 public:
  explicit JsonlWriter(const char* path) {
    if (path != nullptr && path[0] != '\0') file_.open(path, std::ios::app);
  }

  bool enabled() const { return file_.is_open(); }

  void write(const json& value) {
    if (!file_.is_open()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    file_ << value.dump() << '\n';
    file_.flush();
  }

 private:
  std::ofstream file_;
  std::mutex mutex_;
};

struct State {
  Counters counters;
  JsonlWriter activity;
  JsonlWriter events;
  JsonlWriter runtime;
};

std::string getenv_or(const char* name, const char* fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && value[0] != '\0' ? value : fallback;
}

std::vector<unsigned short> parse_ports(const std::string& value) {
  std::vector<unsigned short> ports;
  std::set<unsigned short> seen;
  std::stringstream stream(value);
  std::string item;
  while (std::getline(stream, item, ',')) {
    item.erase(0, item.find_first_not_of(" \t\r\n"));
    item.erase(item.find_last_not_of(" \t\r\n") + 1);
    if (item.empty()) continue;
    int port = std::stoi(item);
    if (port <= 0 || port >= 65536) throw std::runtime_error("invalid port: " + item);
    if (seen.insert(static_cast<unsigned short>(port)).second) ports.push_back(static_cast<unsigned short>(port));
  }
  if (ports.empty()) throw std::runtime_error("PORTS must contain at least one TCP port");
  return ports;
}

std::string now_iso() {
  std::time_t now = std::time(nullptr);
  std::tm tm{};
#if defined(_WIN32)
  gmtime_s(&tm, &now);
#else
  gmtime_r(&now, &tm);
#endif
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tm);
  return buffer;
}

std::int64_t elapsed_seconds() {
  return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - started_at).count();
}

std::uint32_t checksum(const std::string& payload) {
  std::uint32_t value = 2166136261U;
  for (unsigned char byte : payload) {
    value ^= byte;
    value *= 16777619U;
  }
  return value;
}

void record_response(Counters& counters, unsigned status) {
  counters.responses_completed.fetch_add(1, std::memory_order_relaxed);
  if (status >= 200 && status < 300) counters.responses_2xx.fetch_add(1, std::memory_order_relaxed);
  else if (status >= 400 && status < 500) counters.responses_4xx.fetch_add(1, std::memory_order_relaxed);
  else if (status >= 500) counters.responses_5xx.fetch_add(1, std::memory_order_relaxed);
}

json activity_sample(const Counters& counters) {
  return {
      {"ts", now_iso()},
      {"elapsed_seconds", elapsed_seconds()},
      {"active_requests", counters.active_requests.load(std::memory_order_relaxed)},
      {"requests_started_total", counters.requests_started.load(std::memory_order_relaxed)},
      {"responses_completed_total", counters.responses_completed.load(std::memory_order_relaxed)},
      {"responses_2xx_total", counters.responses_2xx.load(std::memory_order_relaxed)},
      {"responses_4xx_total", counters.responses_4xx.load(std::memory_order_relaxed)},
      {"responses_5xx_total", counters.responses_5xx.load(std::memory_order_relaxed)},
      {"request_errors_total", counters.request_errors.load(std::memory_order_relaxed)},
  };
}

json runtime_sample() {
  return {{"ts", now_iso()}, {"elapsed_seconds", elapsed_seconds()}, {"runtime", "cpp-boost-beast"}};
}

void write_event(State& state, const std::string& reason, unsigned status) {
  state.events.write({{"ts", now_iso()}, {"elapsed_seconds", elapsed_seconds()}, {"event", "request_error"}, {"reason", reason}, {"status_code", status}});
}

http::response<http::string_body> json_response(http::status status, const json& value, unsigned version, bool keep_alive) {
  http::response<http::string_body> response{status, version};
  response.set(http::field::content_type, "application/json");
  response.set(http::field::connection, "keep-alive");
  response.keep_alive(keep_alive);
  response.body() = value.dump();
  response.prepare_payload();
  return response;
}

http::response<http::string_body> measured_error(State& state, const std::string& reason, unsigned version, bool keep_alive) {
  state.counters.request_errors.fetch_add(1, std::memory_order_relaxed);
  record_response(state.counters, 400);
  write_event(state, reason, 400);
  return json_response(http::status::bad_request, {{"error", reason}}, version, keep_alive);
}

http::response<http::string_body> handle_request(State& state, const http::request<http::string_body>& request) {
  const std::string target = std::string(request.target());
  const std::string path = target.substr(0, target.find('?'));

  if (path == "/health" && request.method() == http::verb::get) {
    const Counters& c = state.counters;
    return json_response(http::status::ok,
                         {{"ok", true},
                          {"active_requests", c.active_requests.load(std::memory_order_relaxed)},
                          {"requests_started_total", c.requests_started.load(std::memory_order_relaxed)},
                          {"responses_completed_total", c.responses_completed.load(std::memory_order_relaxed)},
                          {"total_errors", c.request_errors.load(std::memory_order_relaxed)}},
                         request.version(), request.keep_alive());
  }

  if (path == "/runtime" && request.method() == http::verb::get) {
    return json_response(http::status::ok, runtime_sample(), request.version(), request.keep_alive());
  }

  if (path != "/json" || request.method() != http::verb::post) {
    return json_response(http::status::not_found, {{"error", "not_found"}}, request.version(), request.keep_alive());
  }

  state.counters.active_requests.fetch_add(1, std::memory_order_relaxed);
  state.counters.requests_started.fetch_add(1, std::memory_order_relaxed);
  auto finish = std::unique_ptr<void, void (*)(void*)>(&state, [](void* ptr) {
    static_cast<State*>(ptr)->counters.active_requests.fetch_sub(1, std::memory_order_relaxed);
  });

  json body;
  try {
    body = json::parse(request.body());
  } catch (const json::parse_error&) {
    return measured_error(state, "invalid_json", request.version(), request.keep_alive());
  }
  if (!body.is_object() || !body.contains("id") || !body.contains("payload") || !body["payload"].is_string()) {
    return measured_error(state, "invalid_request", request.version(), request.keep_alive());
  }
  std::uint64_t id = 0;
  const json& id_value = body["id"];
  if (id_value.is_number_unsigned()) {
    id = id_value.get<std::uint64_t>();
  } else if (id_value.is_number_integer()) {
    const auto signed_id = id_value.get<std::int64_t>();
    if (signed_id < 0) {
      return measured_error(state, "invalid_request", request.version(), request.keep_alive());
    }
    id = static_cast<std::uint64_t>(signed_id);
  } else {
    return measured_error(state, "invalid_request", request.version(), request.keep_alive());
  }
  if (id > max_safe_integer) {
    return measured_error(state, "invalid_request", request.version(), request.keep_alive());
  }
  std::string payload = body["payload"].get<std::string>();
  record_response(state.counters, 200);
  return json_response(http::status::ok, {{"id", id}, {"len", payload.size()}, {"checksum", checksum(payload)}}, request.version(), request.keep_alive());
}

void session(tcp::socket socket, State& state) {
  beast::flat_buffer buffer;
  beast::error_code error;
  while (!stopping.load(std::memory_order_relaxed)) {
    http::request<http::string_body> request;
    http::read(socket, buffer, request, error);
    if (error == http::error::end_of_stream) break;
    if (error) break;
    auto response = handle_request(state, request);
    bool keep_alive = response.keep_alive();
    http::write(socket, response, error);
    if (error || !keep_alive) break;
  }
  socket.shutdown(tcp::socket::shutdown_send, error);
}

void listen_on(const std::string& host, unsigned short port, State& state) {
  asio::io_context ioc{1};
  tcp::endpoint endpoint{asio::ip::make_address(host), port};
  tcp::acceptor acceptor{ioc};
  acceptor.open(endpoint.protocol());
  acceptor.set_option(asio::socket_base::reuse_address(true));
  acceptor.bind(endpoint);
  acceptor.listen(asio::socket_base::max_listen_connections);
  std::cout << "C++ Boost.Beast JSON server listening on http://" << host << ':' << port << std::endl;
  while (!stopping.load(std::memory_order_relaxed)) {
    beast::error_code error;
    tcp::socket socket{ioc};
    acceptor.accept(socket, error);
    if (error) continue;
    std::thread{session, std::move(socket), std::ref(state)}.detach();
  }
}

void on_signal(int) { stopping.store(true, std::memory_order_relaxed); }

int main() {
  std::signal(SIGINT, on_signal);
  std::signal(SIGTERM, on_signal);

  std::string host = getenv_or("HOST", "127.0.0.1");
  std::string ports_value = getenv_or("PORTS", std::getenv("PORT") != nullptr ? std::getenv("PORT") : "8080");
  std::vector<unsigned short> ports = parse_ports(ports_value);
  State state{Counters{}, JsonlWriter(std::getenv("ACTIVITY_METRICS_PATH")), JsonlWriter(std::getenv("SERVER_EVENTS_PATH")), JsonlWriter(std::getenv("RUNTIME_METRICS_PATH"))};

  std::vector<std::thread> listeners;
  for (unsigned short port : ports) listeners.emplace_back(listen_on, host, port, std::ref(state));

  if (state.activity.enabled()) state.activity.write(activity_sample(state.counters));
  if (state.runtime.enabled()) state.runtime.write(runtime_sample());
  while (!stopping.load(std::memory_order_relaxed)) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
    if (state.activity.enabled()) state.activity.write(activity_sample(state.counters));
    if (state.runtime.enabled()) state.runtime.write(runtime_sample());
  }

  for (auto& thread : listeners) {
    if (thread.joinable()) thread.detach();
  }
  return 0;
}
