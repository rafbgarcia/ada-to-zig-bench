defmodule BenchElixirPlug.Metrics do
  @started_at System.monotonic_time(:millisecond)

  def activity_sample do
    counters = BenchElixirPlug.Counters.snapshot()

    Map.merge(counters, %{
      ts: now_iso(),
      elapsed_seconds: elapsed_seconds()
    })
  end

  def runtime_sample do
    memory = :erlang.memory()
    stats = :erlang.statistics(:garbage_collection)

    %{
      ts: now_iso(),
      elapsed_seconds: elapsed_seconds(),
      runtime: "elixir-plug-cowboy",
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      total_memory_bytes: Keyword.get(memory, :total),
      processes_memory_bytes: Keyword.get(memory, :processes),
      atom_memory_bytes: Keyword.get(memory, :atom),
      binary_memory_bytes: Keyword.get(memory, :binary),
      ets_memory_bytes: Keyword.get(memory, :ets),
      gc_cycles_total: elem(stats, 0),
      gc_words_reclaimed_total: elem(stats, 1)
    }
  end

  def now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def elapsed_seconds do
    System.monotonic_time(:millisecond)
    |> Kernel.-(@started_at)
    |> div(1000)
  end
end
