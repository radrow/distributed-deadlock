-module(tracer).

-include("ddmon.hrl").

-export([ start_link/1, start_link/2
        , finish/1, finish/2
        , add_tracee_glob/0, add_tracee_glob/1
        ]).


start_link(Procs) ->
    start_link(Procs, []).

start_link(Procs, Opts) ->
    Init = self(),
    Tracer = spawn_link(fun() -> run_tracer(Init, Procs, Opts) end),
    receive {Tracer, ready} -> ok end,
    true = register(dls_tracer, Tracer),
    Tracer.


run_tracer(Init, Procs, Opts) ->
    config_tracer(Opts),

    TraceProc = proplists:get_value(trace_proc, Opts, false),
    TraceMon = proplists:get_value(trace_mon, Opts, true),
    put(trace_int, proplists:get_value(trace_int, Opts, true)),
    put(live_log, proplists:get_value(live_log, Opts, false)),

    [ begin
          [add_tracee(P) || TraceProc],
          [add_tracee(M) || TraceMon],
          ok
      end
      || {M, P} <- Procs
    ],
    put({type, Init}, init),
    put(init_time, erlang:monotonic_time()),

    Init ! {self(), ready},

    loop([]).

add_tracee({Who, Kind, Id}) ->
    logging:remember(Who, Kind, Id),
    io:format("### ADDING TRACEE: ~w AS ~w - ~w\n", [Who, Kind, Id]),
    add_tracee(Who);
add_tracee(Who) ->
    TraceOpts = ['send', 'receive', 'call', strict_monotonic_timestamp],
    erlang:trace(Who, true, TraceOpts).

add_tracee_glob() ->
    add_tracee_glob(self()).
add_tracee_glob(Who) ->
    Self = self(),
    dls_tracer ! {add, Self, Who},
    receive {ok, {add, Self, Who}} -> ok end.

config_tracer(Opts) ->
    {module, ddmon} = code:ensure_loaded(ddmon),

    logging:conf(Opts),

    erlang:trace_pattern(
      'send',
      [ {['_', {'$gen_call', '_', '_'}], [], []} % gen_server call
      , {['_', {'_', '_'}], [], []} % gen_server reply
      ]
     ),
    erlang:trace_pattern(
      'receive',
      [ {['_', '_', {'$gen_call', '_', '_'}], [], []} % gen_server call
      , {['_', '_', {'$1', '_'}], [{'=/=', '$1', code_server}], []} % gen_server reply
      ]
     ),

    erlang:trace_pattern( % TODO in OTP27 wildcard function name
      {ddmon, unlocked, 3},
      [ {['_', '_', '_'], [], [trace]} ]
     ),
    erlang:trace_pattern(
      {ddmon, locked, 3},
      [ {['_', '_', '_'], [], [trace]} ]
     ),
    erlang:trace_pattern(
      {ddmon, deadlocked, 3},
      [ {['_', '_', '_'], [], [trace]} ]
     ),

    erlang:trace_pattern(
      {'Elixir.Dlstalk.TestServer', wait, 1},
      [ {['_'], [], [trace]} ],
      [local]
     ),

    ok.


loop(Log) ->
    receive
        {add, From, Who} ->
            add_tracee(Who),
            From ! {ok, {add, From, Who}},
            loop(Log);
        {From, finito} ->
            From ! {self(), lists:reverse(Log)},
            ok;
        Trace ->
            El = handle(Trace),
            [logging:log_trace(get(init_time), El) || get(live_log)],
            loop([El|Log])
    end.


finish(Tracer) ->
    finish(Tracer, []).

finish(Tracer, Tracees) when is_atom(Tracer) ->
    finish(whereis(Tracer), Tracees);
finish(Tracer, Tracees) ->
    Refs = [ erlang:trace_delivered(Tracee) || Tracee <- Tracees ],
    [ receive {trace_delivered, _, Ref} -> ok end || Ref <- Refs],

    Tracer ! {self(), finito},
    receive
        {Tracer, Log} ->
            Log
    end.

-define(IF_OPT(OPT, LOG), case get(OPT) of true -> LOG; _ -> ignore end).

%% State change
handle({trace_ts, Who, 'call',
        {ddmon, State, [enter, _, Internal]}, Time}) ->
    case State of
        unlocked ->
            {Time, Who, {state, unlocked}};
        locked ->
            {Time, Who, {state, {locked, ddmon:state_get_req_tag(Internal)}}};
        deadlocked ->
            {Time, Who, {state, {deadlocked, ddmon:deadstate_get_deadlock(Internal)}}}
    end;

%% Pick query

handle({trace_ts, Who, 'call',
        {ddmon, _, [{call, {From, _}}, Msg, Internal]}, Time}) ->
    ?IF_OPT(trace_int,
            case ddmon:state_get_worker(Internal) == From of
                false ->
                    %% External
                    {Time, Who, {pick, {query, From, Msg}}};
                true ->
                    %% Process calls
                    {ProcMsg, Server} = Msg,
                    {Time, Who, {pick, {proc_query, Server, ProcMsg}}}
            end);

%% Pick reply (unlocked --- from proc)
handle({trace_ts, Who, 'call',
        {ddmon, unlocked, [info, {_From, Msg}, _]}, Time}) ->

    ?IF_OPT(trace_int, {Time, Who, {pick, {proc_reply, Msg}}});

%% Pick reply (locked --- external)
handle({trace_ts, Who, 'call',
        {ddmon, locked, [info, {_From, Msg}, _]}, Time}) ->
    ?IF_OPT(trace_int, {Time, Who, {pick, {reply, Msg}}});

%% Pick deadlock notification
handle({trace_ts, _Who, 'call',
        {ddmon, _, [info, {_, {?YOU_DIED, _}}, _]}, _Time}) ->
    ignore;

%% Pick probe
handle({trace_ts, Who, 'call',
        {ddmon, _, [cast, {?PROBE, Probe, _Chain}, _]}, Time}) ->
    ?IF_OPT(trace_int, {Time, Who, {pick, {probe, Probe}}});

%% Pick cast
handle({trace_ts, _Who, 'call',
        {ddmon, _, [cast, {_From, _Msg}, _]}, _Time}) ->
    ignore;

%% Pick scheduled probe
handle({trace_ts, _Who, 'call',
        {ddmon, _, [cast, {?SCHEDULED_PROBE, _, _}, _]}, _Time}) ->
    ignore;

%% Receive query (gen_statem --- no alias)
handle({trace_ts, Who, 'receive',
        {'$gen_call', {FromPid, ReqId}, Msg},
        Time
       }) when is_reference(ReqId) ->
    ?IF_OPT(trace_int, {Time, Who, {recv, {query, FromPid, Msg}}});

%% Receive query (gen_server --- with alias)
handle({trace_ts, Who, 'receive',
        {'$gen_call', {FromPid, [alias|ReqId]}, Msg},
        Time
       }) when is_reference(ReqId) ->
    put({alias, ReqId}, FromPid),
    {Time, Who, {recv, {query, FromPid, Msg}}};

%% Receive reply (gen_statem --- no alias)
handle({trace_ts, Who, 'receive',
        {ReqId, Msg},
        Time
       }) when is_reference(ReqId) ->
    {Time, Who, {recv, {reply, Msg}}};

%% Receive reply (gen_server --- with alias)
handle({trace_ts, Who, 'receive',
        {[alias|ReqId], Msg},
        Time
       }) when is_reference(ReqId) ->
    ?IF_OPT(trace_int, {Time, Who, {recv, {reply, Msg}}});

%% Receive probe
handle({trace_ts, Who, 'receive',
        {'$gen_cast', {?PROBE, Probe, _Chain}},
        Time
       }) ->
    {Time, Who, {recv, {probe, Probe}}};

%% Router release
handle({trace_ts, Who, 'receive',
        {'$gen_cast', {release, Pid}},
        Time
       }) ->
    {Time, Who, {recv, {release, Pid}}};

%% Scheduled probe
handle({trace_ts, _Who, 'receive',
        {'$gen_cast', {?SCHEDULED_PROBE, _ToProbe, _Probe}},
        _Time
       }) ->
    ignore;

%% Deadlock notification
handle({trace_ts, _Who, 'receive',
        {_, {?YOU_DIED, _DL}},
        _Time
       }) ->
    ignore;

%% Send query (gen_statem --- no alias)
handle({trace_ts, Who, 'send',
        {'$gen_call', _From, Msg}, To,
        Time
       }) ->
    Log = {Time, Who, {send, To, {query, Msg}}},
    case {logging:type(Who), logging:type(To)} of
        {'M', 'P'} -> ?IF_OPT(trace_int, Log);
        _ -> Log
    end;

%% Send reply (gen_server --- with alias)
handle({trace_ts, Who, 'send',
        {[alias|ReqId], Msg}, ReqId,
        Time
       }) when is_reference(ReqId) ->
    To = get({alias, ReqId}),
    {Time, Who, {send, To, {reply, Msg}}};

%% Send reply (gen_statem --- no alias)
handle({trace_ts, Who, 'send',
        {ReqId, Msg}, To,
        Time
       }) when is_reference(ReqId) ->
    ?IF_OPT(trace_int, {Time, Who, {send, To, {reply, Msg}}});

%% Send probe
handle({trace_ts, Who, 'send',
        {'$gen_cast', {?PROBE, Probe, _Chain}}, To,
        Time
       }) ->
    {Time, Who, {send, To, {probe, Probe}}};

%% Router release
handle({trace_ts, Who, send,
        {'$gen_cast', {release, Pid}}, To,
        Time
       }) ->
    ?IF_OPT(trace_int, {Time, Who, {send, To, {release, Pid}}});

%% Scheduled probe
handle({trace_ts, _Who, send,
        {'$gen_cast', {?SCHEDULED_PROBE, _ToProbe, _Probe}}, _To,
        _Time
       }) ->
    ignore;

%% Deadlock notification
handle({trace_ts, _Who, send,
        {_, {?YOU_DIED, _DL}}, _To,
        _Time
       }) ->
    ignore;

%% Process waiting
handle({trace_ts, Who, 'call',
        {Module, wait, [WaitFor]}, Time}) when Module =:= 'Elixir.Dlstalk.TestServer' ->
    ?IF_OPT(trace_int, {Time, Who, {wait, WaitFor}});

%% Unhandled
handle(Trace) when element(1, Trace) =:= trace_ts ->
    Time = lists:last(tuple_to_list(Trace)),
    {Time, element(2, Trace), {unhandled, Trace}};

handle(Trace) when element(1, Trace) =:= trace ->
    Time = erlang:monotonic_time(),
    {Time, element(2, Trace), {unhandled, Trace}}.
