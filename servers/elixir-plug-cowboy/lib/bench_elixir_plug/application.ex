defmodule BenchElixirPlug.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    host = System.get_env("HOST") || "127.0.0.1"

    with {:ok, ports} <- parse_ports(System.get_env("PORTS") || System.get_env("PORT") || "8080"),
         {:ok, ip} <- parse_host(host) do
      children =
        [
          BenchElixirPlug.Counters,
          writer_child(BenchElixirPlug.ActivityWriter, System.get_env("ACTIVITY_METRICS_PATH")),
          writer_child(BenchElixirPlug.EventWriter, System.get_env("SERVER_EVENTS_PATH")),
          writer_child(BenchElixirPlug.RuntimeWriter, System.get_env("RUNTIME_METRICS_PATH")),
          sampler_child(:activity_sampler, BenchElixirPlug.ActivityWriter, &BenchElixirPlug.Metrics.activity_sample/0),
          sampler_child(:runtime_sampler, BenchElixirPlug.RuntimeWriter, &BenchElixirPlug.Metrics.runtime_sample/0)
        ] ++ cowboy_children(ip, host, ports)

      Supervisor.start_link(children, strategy: :one_for_one, name: BenchElixirPlug.Supervisor)
    else
      {:error, reason} ->
        Logger.error("elixir-plug-cowboy: #{reason}")
        System.stop(1)
        :ignore
    end
  end

  defp cowboy_children(ip, host, ports) do
    Enum.map(ports, fn port ->
      IO.puts("elixir Plug.Cowboy JSON server listening on http://#{host}:#{port}")
      ref = {:bench_elixir_plug, port}

      Supervisor.child_spec(
        {Plug.Cowboy,
         scheme: :http,
         plug: BenchElixirPlug.Router,
         options: [
           ip: ip,
           port: port,
           transport_options: [
             num_acceptors: 256,
             max_connections: :infinity,
             socket_opts: [backlog: 65_535, nodelay: true, reuseaddr: true]
           ],
           protocol_options: [idle_timeout: 120_000, max_keepalive: 1_000_000]
         ],
         ref: ref},
        id: ref
      )
    end)
  end

  defp writer_child(name, path) do
    Supervisor.child_spec({BenchElixirPlug.JsonlWriter, name: name, path: path}, id: name)
  end

  defp sampler_child(id, writer, sample) do
    Supervisor.child_spec({BenchElixirPlug.Sampler, writer: writer, sample: sample}, id: id)
  end

  defp parse_host(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "invalid HOST #{inspect(host)}"}
    end
  end

  defp parse_ports(value) do
    ports =
      value
      |> String.split(",")
      |> Enum.reduce_while({:ok, MapSet.new(), []}, fn item, {:ok, seen, ports} ->
        item = String.trim(item)

        cond do
          item == "" ->
            {:cont, {:ok, seen, ports}}

          true ->
            case Integer.parse(item) do
              {port, ""} when port > 0 and port < 65_536 ->
                if MapSet.member?(seen, port) do
                  {:cont, {:ok, seen, ports}}
                else
                  {:cont, {:ok, MapSet.put(seen, port), [port | ports]}}
                end

              _ ->
                {:halt, {:error, "invalid port #{inspect(item)}"}}
            end
        end
      end)

    case ports do
      {:ok, _seen, []} -> {:error, "PORTS must contain at least one TCP port"}
      {:ok, _seen, ports} -> {:ok, Enum.reverse(ports)}
      {:error, reason} -> {:error, reason}
    end
  end
end
