-module(bench_erlang_cowboy_sampler).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Writer, SampleFun) ->
    gen_server:start_link(?MODULE, {Writer, SampleFun}, []).

init({Writer, SampleFun}) ->
    Enabled = bench_erlang_cowboy_jsonl_writer:enabled(Writer),
    State = #{writer => Writer, sample => SampleFun, enabled => Enabled},
    case Enabled of
        true ->
            bench_erlang_cowboy_jsonl_writer:write(Writer, SampleFun()),
            erlang:send_after(1000, self(), sample);
        false ->
            ok
    end,
    {ok, State}.

handle_info(sample, #{enabled := true, writer := Writer, sample := SampleFun} = State) ->
    bench_erlang_cowboy_jsonl_writer:write(Writer, SampleFun()),
    erlang:send_after(1000, self(), sample),
    {noreply, State};
handle_info(sample, State) ->
    {noreply, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.
