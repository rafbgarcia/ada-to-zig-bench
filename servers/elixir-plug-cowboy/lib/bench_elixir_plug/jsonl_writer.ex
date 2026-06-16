defmodule BenchElixirPlug.JsonlWriter do
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.get(opts, :path)
    GenServer.start_link(__MODULE__, path, name: name)
  end

  def enabled?(name) do
    GenServer.call(name, :enabled?)
  end

  def write(name, value) do
    GenServer.cast(name, {:write, value})
  end

  @impl true
  def init(nil), do: {:ok, nil}
  def init(""), do: {:ok, nil}

  def init(path) do
    case File.open(path, [:append, :utf8]) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> {:stop, {:open_metrics_file, path, reason}}
    end
  end

  @impl true
  def handle_call(:enabled?, _from, file) do
    {:reply, file != nil, file}
  end

  @impl true
  def handle_cast({:write, _value}, nil), do: {:noreply, nil}

  def handle_cast({:write, value}, file) do
    IO.write(file, Jason.encode_to_iodata!(value))
    IO.write(file, "\n")
    {:noreply, file}
  end

  @impl true
  def terminate(_reason, nil), do: :ok
  def terminate(_reason, file), do: File.close(file)
end
