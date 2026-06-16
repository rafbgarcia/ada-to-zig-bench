require 'json'
require 'objspace'
require 'socket'
require 'time'
require 'webrick'

MAX_SAFE_INTEGER = 9_007_199_254_740_991
STARTED_AT_MONOTONIC = Process.clock_gettime(Process::CLOCK_MONOTONIC)

class Counters
  attr_reader :lock

  def initialize
    @lock = Mutex.new
    @active_requests = 0
    @requests_started = 0
    @responses_completed = 0
    @responses_2xx = 0
    @responses_4xx = 0
    @responses_5xx = 0
    @request_errors = 0
  end

  def start_request
    @lock.synchronize do
      @active_requests += 1
      @requests_started += 1
    end
  end

  def finish_request
    @lock.synchronize { @active_requests -= 1 }
  end

  def record_response(status)
    @lock.synchronize do
      @responses_completed += 1
      if status >= 200 && status < 300
        @responses_2xx += 1
      elsif status >= 400 && status < 500
        @responses_4xx += 1
      elsif status >= 500
        @responses_5xx += 1
      end
    end
  end

  def record_error
    @lock.synchronize { @request_errors += 1 }
  end

  def snapshot
    @lock.synchronize do
      {
        active_requests: @active_requests,
        requests_started_total: @requests_started,
        responses_completed_total: @responses_completed,
        responses_2xx_total: @responses_2xx,
        responses_4xx_total: @responses_4xx,
        responses_5xx_total: @responses_5xx,
        request_errors_total: @request_errors
      }
    end
  end
end

class JsonlWriter
  def initialize(path)
    @file = path && !path.empty? ? File.open(path, 'a') : nil
    @lock = Mutex.new
  end

  def write(value)
    return unless @file

    @lock.synchronize do
      @file.write(JSON.generate(value))
      @file.write("\n")
      @file.flush
    end
  end

  def close
    @file&.close
  end
end

def main
  host = ENV.fetch('HOST', '127.0.0.1')
  ports = parse_ports(ENV['PORTS'] || ENV['PORT'] || '8080')
  counters = Counters.new
  activity = JsonlWriter.new(ENV['ACTIVITY_METRICS_PATH'])
  events = JsonlWriter.new(ENV['SERVER_EVENTS_PATH'])
  runtime = JsonlWriter.new(ENV['RUNTIME_METRICS_PATH'])

  stop = false
  servers = ports.map do |port|
    server = WEBrick::HTTPServer.new(
      BindAddress: host,
      Port: port,
      AccessLog: [],
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
      DoNotReverseLookup: true,
      RequestTimeout: 120
    )
    mount_handlers(server, counters, events)
    puts "ruby WEBrick JSON server listening on http://#{host}:#{port}"
    Thread.new { server.start }
    server
  end

  sampler_threads = []
  unless ENV['ACTIVITY_METRICS_PATH'].to_s.empty?
    activity.write(activity_sample(counters))
    sampler_threads << Thread.new { sample_every(activity) { activity_sample(counters) } }
  end
  unless ENV['RUNTIME_METRICS_PATH'].to_s.empty?
    runtime.write(runtime_sample)
    sampler_threads << Thread.new { sample_every(runtime) { runtime_sample } }
  end

  Signal.trap('TERM') { stop = true }
  Signal.trap('INT') { stop = true }
  sleep 0.1 until stop
ensure
  sampler_threads&.each(&:kill)
  servers&.each(&:shutdown)
  activity&.close
  events&.close
  runtime&.close
end

def mount_handlers(server, counters, events)
  server.mount_proc('/health') do |_req, res|
    snap = counters.snapshot
    write_json(res, 200, {
      ok: true,
      active_requests: snap[:active_requests],
      requests_started_total: snap[:requests_started_total],
      responses_completed_total: snap[:responses_completed_total],
      total_errors: snap[:request_errors_total]
    })
  end

  server.mount_proc('/runtime') do |_req, res|
    write_json(res, 200, runtime_sample)
  end

  server.mount_proc('/json') do |req, res|
    unless req.request_method == 'POST'
      write_json(res, 404, { error: 'not_found' })
      next
    end

    counters.start_request
    begin
      begin
        body = JSON.parse(req.body.to_s)
      rescue JSON::ParserError
        measured_error(res, counters, events, 'invalid_json')
        next
      end

      unless body.is_a?(Hash) && valid_id?(body['id']) && body['payload'].is_a?(String)
        measured_error(res, counters, events, 'invalid_request')
        next
      end

      payload = body['payload'].encode('UTF-8')
      counters.record_response(200)
      write_json(res, 200, {
        id: body['id'],
        len: payload.bytesize,
        checksum: checksum(payload.bytes)
      })
    ensure
      counters.finish_request
    end
  end

  server.mount_proc('/') do |_req, res|
    write_json(res, 404, { error: 'not_found' })
  end
end

def measured_error(res, counters, events, reason)
  counters.record_error
  counters.record_response(400)
  write_event(events, 'request_error', reason: reason, status_code: 400)
  write_json(res, 400, { error: reason })
end

def write_json(res, status, value)
  body = JSON.generate(value)
  res.status = status
  res['Connection'] = 'keep-alive'
  res['Content-Type'] = 'application/json'
  res['Content-Length'] = body.bytesize.to_s
  res.body = body
end

def checksum(bytes)
  value = 2_166_136_261
  bytes.each do |byte|
    value ^= byte
    value = (value * 16_777_619) & 0xffffffff
  end
  value
end

def valid_id?(value)
  value.is_a?(Integer) && value >= 0 && value <= MAX_SAFE_INTEGER
end

def activity_sample(counters)
  counters.snapshot.merge(
    ts: now_iso,
    elapsed_seconds: elapsed_seconds
  )
end

def runtime_sample
  {
    ts: now_iso,
    elapsed_seconds: elapsed_seconds,
    runtime: 'ruby-webrick',
    heap_used_bytes: ObjectSpace.memsize_of_all,
    gc_count: GC.count
  }
end

def write_event(writer, event, fields)
  writer.write({ ts: now_iso, elapsed_seconds: elapsed_seconds, event: event }.merge(fields))
end

def sample_every(writer)
  loop do
    sleep 1
    writer.write(yield)
  end
end

def now_iso
  Time.now.utc.iso8601
end

def elapsed_seconds
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - STARTED_AT_MONOTONIC).to_i
end

def parse_ports(value)
  seen = {}
  ports = []
  value.split(',').each do |item|
    item = item.strip
    next if item.empty?

    port = Integer(item, 10)
    raise ArgumentError, "invalid port #{item.inspect}" unless port.positive? && port < 65_536
    next if seen[port]

    seen[port] = true
    ports << port
  end
  raise ArgumentError, 'PORTS must contain at least one TCP port' if ports.empty?
  ports
end

main
