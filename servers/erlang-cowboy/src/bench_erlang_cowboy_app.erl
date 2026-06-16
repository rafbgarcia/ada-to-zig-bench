-module(bench_erlang_cowboy_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Host = get_env("HOST", "127.0.0.1"),
    case {parse_host(Host), parse_ports(first_non_empty([os:getenv("PORTS"), os:getenv("PORT"), "8080"]))} of
        {{ok, Ip}, {ok, Ports}} ->
            bench_erlang_cowboy_metrics:init(),
            case bench_erlang_cowboy_sup:start_link(Ip, Host, Ports) of
                {ok, Pid} ->
                    start_listeners(Ip, Host, Ports),
                    {ok, Pid};
                Error ->
                    Error
            end;
        {{error, Reason}, _} ->
            io:format(standard_error, "erlang-cowboy: ~s~n", [Reason]),
            {error, Reason};
        {_, {error, Reason}} ->
            io:format(standard_error, "erlang-cowboy: ~s~n", [Reason]),
            {error, Reason}
    end.

stop(_State) ->
    ok.

start_listeners(Ip, Host, Ports) ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/health", bench_erlang_cowboy_handler, health},
        {"/runtime", bench_erlang_cowboy_handler, runtime},
        {"/json", bench_erlang_cowboy_handler, json},
        {'_', bench_erlang_cowboy_handler, not_found}
    ]}]),
    lists:foreach(fun(Port) ->
        Ref = list_to_atom("bench_erlang_cowboy_" ++ integer_to_list(Port)),
        {ok, _} = cowboy:start_clear(
            Ref,
            [{ip, Ip}, {port, Port}],
            #{env => #{dispatch => Dispatch}, idle_timeout => 120000}
        ),
        io:format("erlang Cowboy JSON server listening on http://~s:~B~n", [Host, Port])
    end, Ports).

get_env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

first_non_empty([]) ->
    "";
first_non_empty([false | Rest]) ->
    first_non_empty(Rest);
first_non_empty(["" | Rest]) ->
    first_non_empty(Rest);
first_non_empty([Value | _Rest]) ->
    Value.

parse_host(Host) ->
    case inet:parse_address(Host) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> {error, "invalid HOST " ++ Host}
    end.

parse_ports(Value) ->
    parse_ports(string:tokens(Value, ","), #{}, []).

parse_ports([], _Seen, []) ->
    {error, "PORTS must contain at least one TCP port"};
parse_ports([], _Seen, Ports) ->
    {ok, lists:reverse(Ports)};
parse_ports([Item0 | Rest], Seen, Ports) ->
    Item = string:trim(Item0),
    case Item of
        "" ->
            parse_ports(Rest, Seen, Ports);
        _ ->
            case string:to_integer(Item) of
                {Port, []} when Port > 0, Port < 65536 ->
                    case maps:is_key(Port, Seen) of
                        true -> parse_ports(Rest, Seen, Ports);
                        false -> parse_ports(Rest, Seen#{Port => true}, [Port | Ports])
                    end;
                _ ->
                    {error, "invalid port " ++ Item}
            end
    end.
