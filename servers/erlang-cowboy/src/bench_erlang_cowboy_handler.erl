-module(bench_erlang_cowboy_handler).

-export([init/2]).

-define(MAX_SAFE_INTEGER, 9007199254740991).

init(Req0, health) ->
    Snapshot = bench_erlang_cowboy_counters:snapshot(),
    Body = #{
        ok => true,
        active_requests => maps:get(active_requests, Snapshot),
        requests_started_total => maps:get(requests_started_total, Snapshot),
        responses_completed_total => maps:get(responses_completed_total, Snapshot),
        total_errors => maps:get(request_errors_total, Snapshot)
    },
    {ok, reply_json(Req0, 200, Body), health};
init(Req0, runtime) ->
    {ok, reply_json(Req0, 200, bench_erlang_cowboy_metrics:runtime_sample()), runtime};
init(Req0, json) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_json(Req0);
        _ -> {ok, reply_json(Req0, 404, #{error => <<"not_found">>}), json}
    end;
init(Req0, not_found) ->
    {ok, reply_json(Req0, 404, #{error => <<"not_found">>}), not_found}.

handle_json(Req0) ->
    bench_erlang_cowboy_counters:start_request(),
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 1048576}),
        case decode_request(Body) of
            {ok, Id, Payload} ->
                bench_erlang_cowboy_counters:record_response(200),
                PayloadBytes = unicode:characters_to_binary(Payload),
                Response = #{id => Id, len => byte_size(PayloadBytes), checksum => checksum(PayloadBytes)},
                {ok, reply_json(Req1, 200, Response), json};
            {error, invalid_json} ->
                {ok, measured_error(Req1, <<"invalid_json">>), json};
            {error, invalid_request} ->
                {ok, measured_error(Req1, <<"invalid_request">>), json}
        end
    catch
        _:_ ->
            {ok, measured_error(Req0, <<"invalid_json">>), json}
    after
        bench_erlang_cowboy_counters:finish_request()
    end.

decode_request(Body) ->
    try jiffy:decode(Body, [return_maps]) of
        #{<<"id">> := Id, <<"payload">> := Payload} when is_integer(Id), Id >= 0, Id =< ?MAX_SAFE_INTEGER, is_binary(Payload) ->
            {ok, Id, Payload};
        _ ->
            {error, invalid_request}
    catch
        _:_ -> {error, invalid_json}
    end.

measured_error(Req, Reason) ->
    bench_erlang_cowboy_counters:record_error(),
    bench_erlang_cowboy_counters:record_response(400),
    bench_erlang_cowboy_jsonl_writer:write(bench_erlang_event_writer, #{
        ts => bench_erlang_cowboy_metrics:now_iso(),
        elapsed_seconds => bench_erlang_cowboy_metrics:elapsed_seconds(),
        event => <<"request_error">>,
        reason => Reason,
        status_code => 400
    }),
    reply_json(Req, 400, #{error => Reason}).

reply_json(Req, Status, Value) ->
    Body = jiffy:encode(Value),
    cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>,
        <<"content-length">> => integer_to_binary(byte_size(Body)),
        <<"connection">> => <<"keep-alive">>
    }, Body, Req).

checksum(Payload) ->
    checksum(Payload, 2166136261).

checksum(<<>>, Value) ->
    Value;
checksum(<<Byte, Rest/binary>>, Value0) ->
    Value = ((Value0 bxor Byte) * 16777619) band 16#FFFFFFFF,
    checksum(Rest, Value).
