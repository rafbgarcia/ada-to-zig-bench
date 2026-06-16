require "json"
require "objspace"
require "time"

module BenchMetrics
  STARTED_AT_MONOTONIC = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  class Counters
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
      @file = path && !path.empty? ? File.open(path, "a") : nil
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

  class << self
    def start_request
      counters.start_request
    end

    def finish_request
      counters.finish_request
    end

    def record_response(status)
      counters.record_response(status)
    end

    def record_error
      counters.record_error
    end

    def counters_snapshot
      counters.snapshot
    end

    def runtime_sample
      {
        ts: now_iso,
        elapsed_seconds: elapsed_seconds,
        runtime: "ruby-rails-puma",
        heap_used_bytes: ObjectSpace.memsize_of_all,
        gc_count: GC.count
      }
    end

    def write_event(event, fields)
      events.write({ ts: now_iso, elapsed_seconds: elapsed_seconds, event: event }.merge(fields))
    end

    def close
      @sampler_threads&.each(&:kill)
      @activity&.close
      @events&.close
      @runtime&.close
    end

    private

    def counters
      @counters ||= Counters.new
    end

    def activity
      @activity ||= JsonlWriter.new(ENV["ACTIVITY_METRICS_PATH"])
    end

    def events
      @events ||= JsonlWriter.new(ENV["SERVER_EVENTS_PATH"])
    end

    def runtime
      @runtime ||= JsonlWriter.new(ENV["RUNTIME_METRICS_PATH"])
    end

    def start_samplers
      return if @samplers_started

      @samplers_started = true
      @sampler_threads = []

      unless ENV["ACTIVITY_METRICS_PATH"].to_s.empty?
        activity.write(activity_sample)
        @sampler_threads << Thread.new { sample_every(activity) { activity_sample } }
      end

      unless ENV["RUNTIME_METRICS_PATH"].to_s.empty?
        runtime.write(runtime_sample)
        @sampler_threads << Thread.new { sample_every(runtime) { runtime_sample } }
      end
    end

    def activity_sample
      counters.snapshot.merge(ts: now_iso, elapsed_seconds: elapsed_seconds)
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
  end

  start_samplers
end

at_exit { BenchMetrics.close }
