defmodule BenchElixirPlug.Counters do
  use GenServer

  @active_requests 1
  @requests_started_total 2
  @responses_completed_total 3
  @responses_2xx_total 4
  @responses_4xx_total 5
  @responses_5xx_total 6
  @request_errors_total 7
  @counter_count 7
  @counter_ref {__MODULE__, :atomics}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_request do
    counters = counters()
    :atomics.add(counters, @active_requests, 1)
    :atomics.add(counters, @requests_started_total, 1)
  end

  def finish_request do
    :atomics.add(counters(), @active_requests, -1)
  end

  def record_response(status) do
    counters = counters()
    :atomics.add(counters, @responses_completed_total, 1)

    cond do
      status >= 200 and status < 300 -> :atomics.add(counters, @responses_2xx_total, 1)
      status >= 400 and status < 500 -> :atomics.add(counters, @responses_4xx_total, 1)
      status >= 500 -> :atomics.add(counters, @responses_5xx_total, 1)
      true -> :ok
    end
  end

  def record_error do
    :atomics.add(counters(), @request_errors_total, 1)
  end

  def snapshot do
    counters = counters()

    %{
      active_requests: max(:atomics.get(counters, @active_requests), 0),
      requests_started_total: :atomics.get(counters, @requests_started_total),
      responses_completed_total: :atomics.get(counters, @responses_completed_total),
      responses_2xx_total: :atomics.get(counters, @responses_2xx_total),
      responses_4xx_total: :atomics.get(counters, @responses_4xx_total),
      responses_5xx_total: :atomics.get(counters, @responses_5xx_total),
      request_errors_total: :atomics.get(counters, @request_errors_total)
    }
  end

  @impl true
  def init([]) do
    counters = :atomics.new(@counter_count, signed: true)
    :persistent_term.put(@counter_ref, counters)
    {:ok, counters}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot(), state}
  end

  defp counters do
    :persistent_term.get(@counter_ref)
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@counter_ref)
    :ok
  end
end
