-module(bench_erlang_cowboy_counters).
-behaviour(gen_server).

-export([start_link/0, start_request/0, finish_request/0, record_response/1, record_error/0, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

start_request() ->
    gen_server:cast(?MODULE, start_request).

finish_request() ->
    gen_server:cast(?MODULE, finish_request).

record_response(Status) ->
    gen_server:cast(?MODULE, {record_response, Status}).

record_error() ->
    gen_server:cast(?MODULE, record_error).

snapshot() ->
    gen_server:call(?MODULE, snapshot).

init(#{}) ->
    {ok, #{
        active_requests => 0,
        requests_started_total => 0,
        responses_completed_total => 0,
        responses_2xx_total => 0,
        responses_4xx_total => 0,
        responses_5xx_total => 0,
        request_errors_total => 0
    }}.

handle_call(snapshot, _From, State) ->
    {reply, State, State}.

handle_cast(start_request, State) ->
    {noreply, State#{
        active_requests := maps:get(active_requests, State) + 1,
        requests_started_total := maps:get(requests_started_total, State) + 1
    }};
handle_cast(finish_request, State) ->
    {noreply, State#{active_requests := max(maps:get(active_requests, State) - 1, 0)}};
handle_cast(record_error, State) ->
    {noreply, State#{request_errors_total := maps:get(request_errors_total, State) + 1}};
handle_cast({record_response, Status}, State0) ->
    State1 = State0#{responses_completed_total := maps:get(responses_completed_total, State0) + 1},
    State = case Status of
        S when S >= 200, S < 300 ->
            State1#{responses_2xx_total := maps:get(responses_2xx_total, State1) + 1};
        S when S >= 400, S < 500 ->
            State1#{responses_4xx_total := maps:get(responses_4xx_total, State1) + 1};
        S when S >= 500 ->
            State1#{responses_5xx_total := maps:get(responses_5xx_total, State1) + 1};
        _ ->
            State1
    end,
    {noreply, State}.
