-module(bench_erlang_cowboy_sup).
-behaviour(supervisor).

-export([start_link/3]).
-export([init/1]).

start_link(_Ip, _Host, _Ports) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => counters,
          start => {bench_erlang_cowboy_counters, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bench_erlang_cowboy_counters]},
        writer_child(bench_erlang_activity_writer, os:getenv("ACTIVITY_METRICS_PATH")),
        writer_child(bench_erlang_event_writer, os:getenv("SERVER_EVENTS_PATH")),
        writer_child(bench_erlang_runtime_writer, os:getenv("RUNTIME_METRICS_PATH")),
        sampler_child(activity_sampler, bench_erlang_activity_writer, fun bench_erlang_cowboy_metrics:activity_sample/0),
        sampler_child(runtime_sampler, bench_erlang_runtime_writer, fun bench_erlang_cowboy_metrics:runtime_sample/0)
    ],
    {ok, {{one_for_one, 5, 10}, Children}}.

writer_child(Name, Path) ->
    #{id => Name,
      start => {bench_erlang_cowboy_jsonl_writer, start_link, [Name, Path]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [bench_erlang_cowboy_jsonl_writer]}.

sampler_child(Id, Writer, SampleFun) ->
    #{id => Id,
      start => {bench_erlang_cowboy_sampler, start_link, [Writer, SampleFun]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [bench_erlang_cowboy_sampler]}.
