defmodule BenchElixirPlug.Sampler do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    writer = Keyword.fetch!(opts, :writer)
    sample = Keyword.fetch!(opts, :sample)
    state = %{writer: writer, sample: sample, enabled: BenchElixirPlug.JsonlWriter.enabled?(writer)}

    if state.enabled do
      BenchElixirPlug.JsonlWriter.write(writer, sample.())
      Process.send_after(self(), :sample, 1_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:sample, %{enabled: true, writer: writer, sample: sample} = state) do
    BenchElixirPlug.JsonlWriter.write(writer, sample.())
    Process.send_after(self(), :sample, 1_000)
    {:noreply, state}
  end

  def handle_info(:sample, state), do: {:noreply, state}
end
