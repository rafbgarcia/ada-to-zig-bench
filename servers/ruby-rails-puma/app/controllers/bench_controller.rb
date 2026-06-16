require "json"

class BenchController < ActionController::API
  MAX_SAFE_INTEGER = 9_007_199_254_740_991

  def health
    snap = BenchMetrics.counters_snapshot
    write_json(200, {
      ok: true,
      active_requests: snap[:active_requests],
      requests_started_total: snap[:requests_started_total],
      responses_completed_total: snap[:responses_completed_total],
      total_errors: snap[:request_errors_total]
    })
  end

  def runtime
    write_json(200, BenchMetrics.runtime_sample)
  end

  def json
    BenchMetrics.start_request
    begin
      begin
        body = JSON.parse(request.raw_post.to_s)
      rescue JSON::ParserError
        measured_error("invalid_json")
        return
      end

      unless body.is_a?(Hash) && valid_id?(body["id"]) && body["payload"].is_a?(String)
        measured_error("invalid_request")
        return
      end

      payload = body["payload"].encode(Encoding::UTF_8)
      BenchMetrics.record_response(200)
      write_json(200, {
        id: body["id"],
        len: payload.bytesize,
        checksum: checksum(payload.bytes)
      })
    ensure
      BenchMetrics.finish_request
    end
  end

  def not_found
    write_json(404, { error: "not_found" })
  end

  private

  def measured_error(reason)
    BenchMetrics.record_error
    BenchMetrics.record_response(400)
    BenchMetrics.write_event("request_error", reason: reason, status_code: 400)
    write_json(400, { error: reason })
  end

  def write_json(status, value)
    body = JSON.generate(value)
    response.status = status
    response.content_type = "application/json"
    response.headers["Content-Length"] = body.bytesize.to_s
    response.headers["Connection"] = "keep-alive"
    self.response_body = body
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
end
