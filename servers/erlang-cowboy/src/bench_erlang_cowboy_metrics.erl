-module(bench_erlang_cowboy_metrics).

-export([init/0, activity_sample/0, runtime_sample/0, now_iso/0, elapsed_seconds/0]).

init() ->
    persistent_term:put({?MODULE, started_at_ms}, erlang:monotonic_time(millisecond)).

activity_sample() ->
    maps:merge(bench_erlang_cowboy_counters:snapshot(), #{
        ts => now_iso(),
        elapsed_seconds => elapsed_seconds()
    }).

runtime_sample() ->
    {GcCycles, GcWords, _} = erlang:statistics(garbage_collection),
    #{
        ts => now_iso(),
        elapsed_seconds => elapsed_seconds(),
        runtime => <<"erlang-cowboy">>,
        process_count => erlang:system_info(process_count),
        process_limit => erlang:system_info(process_limit),
        total_memory_bytes => erlang:memory(total),
        processes_memory_bytes => erlang:memory(processes),
        atom_memory_bytes => erlang:memory(atom),
        binary_memory_bytes => erlang:memory(binary),
        ets_memory_bytes => erlang:memory(ets),
        gc_cycles_total => GcCycles,
        gc_words_reclaimed_total => GcWords
    }.

now_iso() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}, {offset, "Z"}])).

elapsed_seconds() ->
    StartedAt = persistent_term:get({?MODULE, started_at_ms}, erlang:monotonic_time(millisecond)),
    (erlang:monotonic_time(millisecond) - StartedAt) div 1000.
