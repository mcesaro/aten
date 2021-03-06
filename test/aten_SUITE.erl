-module(aten_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     {group, tests}
    ].

all_tests() ->
    [
     detect_node_partition,
     detect_node_stop_start,
     unregister_does_not_detect,
     register_unknown_emits_down,
     register_detects_down,
     watchers_cleanup
    ].

groups() ->
    [
     {tests, [], all_tests()}
    ].

init_per_group(_, Config) ->
    _ = application:load(aten),
    ok = application:set_env(aten, poll_interval, 500),
    application:ensure_all_started(aten),
    Config.

end_per_group(_, Config) ->
    _ = application:stop(ra),
    Config.

init_per_testcase(_TestCase, Config) ->
    % try to stop all slaves
    [begin
         slave:stop(N),
         ok = aten:unregister(N)
     end || N <- nodes()],
    meck:new(aten_sink, [passthrough]),
    application:stop(aten),
    application:start(aten),
    Config.

end_per_testcase(_Case, _Config) ->
    meck:unload(),
    ok.

detect_node_partition(_Config) ->
    S1 = make_node_name(?FUNCTION_NAME),
    ok = aten:register(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
              exit(node_event_timeout)
    end,
    {ok, S1} = start_slave(?FUNCTION_NAME),
    ct:pal("Node ~w Nodes ~w", [node(), nodes()]),
    receive
        {node_event, S1, up} -> ok
    after 5000 ->
              exit(node_event_timeout)
    end,
    %% give it enough time to generate more than one sample
    timer:sleep(1000),
    simulate_partition(S1),

    receive
        {node_event, S1, down} -> ok
    after 5000 ->
              flush(),
              exit(node_event_timeout)
    end,
    meck:unload(aten_sink),

    receive
        {node_event, S1, up} -> ok
    after 5000 ->
              flush(),
              exit(node_event_timeout)
    end,
    ok = slave:stop(S1),
    ok = aten:unregister(S1),
    ok.

detect_node_stop_start(_Config) ->
    S1 = make_node_name(s1),
    ok = aten:register(S1),
    {ok, S1} = start_slave(s1),
    ct:pal("Node ~w Nodes ~w", [node(), nodes()]),
    receive
        {node_event, S1, up} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,

    %% give it enough time to generate more than one sample
    timer:sleep(1000),

    ok = slave:stop(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,

    {ok, S1} = start_slave(s1),
    receive
        {node_event, S1, up} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    ok = slave:stop(S1),
    ok = aten:unregister(S1),
    ok.

unregister_does_not_detect(_Config) ->
    S1 = make_node_name(s1),
    ok = aten:register(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    {ok, S1} = start_slave(s1),
    ct:pal("Node ~w Nodes ~w", [node(), nodes()]),
    receive
        {node_event, S1, up} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    ok = aten:unregister(S1),
    receive
        {node_event, S1, Evt} ->
            exit({unexpected_node_event, S1, Evt})
    after 5000 ->
        ok
    end,
    ok.

register_unknown_emits_down(_Config) ->
    S1 = make_node_name(disconnected_node),
    ok = aten:register(S1),
    % {ok, S1} = start_slave(s1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    ok = aten:unregister(S1),
    ok.

register_detects_down(_Config) ->
    S1 = make_node_name(s1),
    ok = aten:register(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    {ok, S1} = start_slave(s1),
    timer:sleep(500),
    simulate_partition(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    ok = aten:unregister(S1),
    %% re-register should detect down
    ok = aten:register(S1),
    receive
        {node_event, S1, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    ok = aten:unregister(S1),
    ok.

watchers_cleanup(_Config) ->
    Node = make_node_name(s1),
    Self = self(),
    Watcher = spawn_watcher(Node, Self),
    ok = aten:register(Node),
    %% first clear out all the initial notifications
    receive
        {watcher_node_down, Node} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    receive
        {node_event, Node, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    {ok, Node} = start_slave(s1),
    ct:pal("Node ~w Nodes ~w", [node(), nodes()]),
    receive
        {watcher_node_up, Node} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,
    receive
        {node_event, Node, up} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,

    State0 = sys:get_state(aten_detector),
    Watchers0 = element(6, State0),
    #{Node := #{Watcher := _}} = Watchers0,
    #{Node := #{Self := _}} = Watchers0,

    Watcher ! stop,

    timer:sleep(200),
    ok = slave:stop(Node),

    receive
        {watcher_node_down, Node} ->
            exit(stopped_watcher_receive_message)
    after 50 ->
            ok
    end,
    receive
        {node_event, Node, down} -> ok
    after 5000 ->
        exit(node_event_timeout)
    end,

    State1 = sys:get_state(aten_detector),
    Watchers1 = element(6, State1),
    #{Node := Pids} = Watchers1,
    #{Node := #{Self := _}} = Watchers1,
    none = maps:get(Watcher, Pids, none),

    State2 = sys:get_state(aten_sink),
    NodeMap = element(2, State2),
    none = maps:get(Node, NodeMap, none),

    ok = aten:unregister(Node).

spawn_watcher(Node, Pid) ->
    spawn(fun Fun() ->
        ok = aten:register(Node),
        receive
            {node_event, Node, up} ->
                Pid ! {watcher_node_up, Node},
                Fun();
            {node_event, Node, down} ->
                Pid ! {watcher_node_down, Node},
                Fun();
            stop -> ok
        end
    end).


%% simulates a partition from a remote node by dropping messages
%% received from some specific node
simulate_partition(Node) ->
    meck:expect(aten_sink, handle_cast,
                fun ({hb, N}, State) when N =:= Node ->
                        %% drop this message
                        ct:pal("Dropping hb from ~w~n", [Node]),
                        {noreply, State};
                    (Msg, State) ->
                        aten_sink:handle_cast(Msg, State)
                end).

get_current_host() ->
    N = atom_to_list(node()),
    {ok, list_to_atom(after_char($@, N))}.

make_node_name(N) ->
    {ok, Host} = get_current_host(),
    list_to_atom(lists:flatten(io_lib:format("~s@~s", [N, Host]))).

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun (P) -> string:prefix(P, Ld) =:= nomatch end,
                 code:get_path()).
start_slave(N) ->
    {ok, Host} = get_current_host(),
    Pa = string:join(["-pa" | search_paths()] ++ ["-s aten"], " "),
    ct:pal("starting node ~w with ~s~n", [N, Pa]),
    ct_slave:start(Host, N, [{erl_flags, Pa}]).

after_char(_, []) -> [];
after_char(Char, [Char|Rest]) -> Rest;
after_char(Char, [_|Rest]) -> after_char(Char, Rest).


flush() ->
    receive M ->
                ct:pal("flushed ~w~n", [M]),
                flush()
    after 100 ->
              ok
    end.
