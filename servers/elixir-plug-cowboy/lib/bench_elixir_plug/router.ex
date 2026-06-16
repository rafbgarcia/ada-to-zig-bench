defmodule BenchElixirPlug.Router do
  use Plug.Router

  @max_safe_integer 9_007_199_254_740_991

  plug :match
  plug :dispatch

  get "/health" do
    counters = BenchElixirPlug.Counters.snapshot()

    json(conn, 200, %{
      ok: true,
      active_requests: counters.active_requests,
      requests_started_total: counters.requests_started_total,
      responses_completed_total: counters.responses_completed_total,
      total_errors: counters.request_errors_total
    })
  end

  get "/runtime" do
    json(conn, 200, BenchElixirPlug.Metrics.runtime_sample())
  end

  post "/json" do
    BenchElixirPlug.Counters.start_request()

    try do
      with {:ok, body, conn} <- Plug.Conn.read_body(conn, length: 1_048_576),
           {:ok, request} <- Jason.decode(body),
           {:ok, id, payload} <- validate_request(request) do
        payload_bytes = :unicode.characters_to_binary(payload)
        BenchElixirPlug.Counters.record_response(200)

        json(conn, 200, %{
          id: id,
          len: byte_size(payload_bytes),
          checksum: checksum(payload_bytes)
        })
      else
        {:more, _partial, conn} -> measured_error(conn, "invalid_request")
        {:error, %Jason.DecodeError{}} -> measured_error(conn, "invalid_json")
        {:error, _reason} -> measured_error(conn, "invalid_request")
      end
    after
      BenchElixirPlug.Counters.finish_request()
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp validate_request(%{"id" => id, "payload" => payload})
       when is_integer(id) and id >= 0 and id <= @max_safe_integer and is_binary(payload) do
    {:ok, id, payload}
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  defp measured_error(conn, reason) do
    BenchElixirPlug.Counters.record_error()
    BenchElixirPlug.Counters.record_response(400)

    BenchElixirPlug.JsonlWriter.write(BenchElixirPlug.EventWriter, %{
      ts: BenchElixirPlug.Metrics.now_iso(),
      elapsed_seconds: BenchElixirPlug.Metrics.elapsed_seconds(),
      event: "request_error",
      reason: reason,
      status_code: 400
    })

    json(conn, 400, %{error: reason})
  end

  defp json(conn, status, value) do
    body = Jason.encode_to_iodata!(value)

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.put_resp_header("content-length", Integer.to_string(IO.iodata_length(body)))
    |> Plug.Conn.put_resp_header("connection", "keep-alive")
    |> Plug.Conn.send_resp(status, body)
  end

  defp checksum(payload) do
    for <<byte <- payload>>, reduce: 2_166_136_261 do
      value -> Bitwise.band(Bitwise.bxor(value, byte) * 16_777_619, 0xFFFFFFFF)
    end
  end
end
