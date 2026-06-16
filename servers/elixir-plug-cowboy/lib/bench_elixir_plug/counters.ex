defmodule BenchElixirPlug.Counters do
  use GenServer

  defstruct active_requests: 0,
            requests_started_total: 0,
            responses_completed_total: 0,
            responses_2xx_total: 0,
            responses_4xx_total: 0,
            responses_5xx_total: 0,
            request_errors_total: 0

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  def start_request do
    GenServer.cast(__MODULE__, :start_request)
  end

  def finish_request do
    GenServer.cast(__MODULE__, :finish_request)
  end

  def record_response(status) do
    GenServer.cast(__MODULE__, {:record_response, status})
  end

  def record_error do
    GenServer.cast(__MODULE__, :record_error)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(:start_request, state) do
    {:noreply, %{state | active_requests: state.active_requests + 1, requests_started_total: state.requests_started_total + 1}}
  end

  def handle_cast(:finish_request, state) do
    {:noreply, %{state | active_requests: max(state.active_requests - 1, 0)}}
  end

  def handle_cast(:record_error, state) do
    {:noreply, %{state | request_errors_total: state.request_errors_total + 1}}
  end

  def handle_cast({:record_response, status}, state) do
    state = %{state | responses_completed_total: state.responses_completed_total + 1}

    state =
      cond do
        status >= 200 and status < 300 -> %{state | responses_2xx_total: state.responses_2xx_total + 1}
        status >= 400 and status < 500 -> %{state | responses_4xx_total: state.responses_4xx_total + 1}
        status >= 500 -> %{state | responses_5xx_total: state.responses_5xx_total + 1}
        true -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.from_struct(state), state}
  end
end
