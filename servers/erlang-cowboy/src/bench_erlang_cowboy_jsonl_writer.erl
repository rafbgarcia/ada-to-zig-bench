-module(bench_erlang_cowboy_jsonl_writer).
-behaviour(gen_server).

-export([start_link/2, enabled/1, write/2]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link(Name, Path) ->
    gen_server:start_link({local, Name}, ?MODULE, Path, []).

enabled(Name) ->
    gen_server:call(Name, enabled).

write(Name, Value) ->
    gen_server:cast(Name, {write, Value}).

init(false) ->
    {ok, disabled};
init("") ->
    {ok, disabled};
init(Path) ->
    case file:open(Path, [append, raw]) of
        {ok, File} -> {ok, File};
        {error, Reason} -> {stop, {open_metrics_file, Path, Reason}}
    end.

handle_call(enabled, _From, disabled) ->
    {reply, false, disabled};
handle_call(enabled, _From, File) ->
    {reply, File =/= disabled, File}.

handle_cast({write, _Value}, disabled) ->
    {noreply, disabled};
handle_cast({write, Value}, File) ->
    ok = file:write(File, jiffy:encode(Value)),
    ok = file:write(File, <<"\n">>),
    {noreply, File}.

terminate(_Reason, disabled) ->
    ok;
terminate(_Reason, File) ->
    file:close(File).
