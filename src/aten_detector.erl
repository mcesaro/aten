-module(aten_detector).

-behaviour(gen_server).

%% API functions
-export([start_link/0,
         register/1,
         unregister/1
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(POLL_INTERVAL_MS, 1000).
-define(DEFAULT_THRESHOLD, 0.99).

-record(state, {tref :: reference() | undefined,
                interval = ?POLL_INTERVAL_MS :: non_neg_integer(),
                threshold = ?DEFAULT_THRESHOLD :: float(),
                node_states = #{} :: #{node() => float()}, % last threshold
                watchers = #{} :: #{node() => #{pid() => reference()}}}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Node) ->
    Me = self(),
    gen_server:cast(?MODULE, {register, Node, Me}).

unregister(Node) ->
    Me = self(),
    gen_server:cast(?MODULE, {unregister, Node, Me}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Thresh = application:get_env(aten, detection_threshold,
                                 ?DEFAULT_THRESHOLD),
    Interval = application:get_env(aten, poll_interval,
                                   ?POLL_INTERVAL_MS),
    {ok, set_timer(#state{threshold = Thresh,
                          interval = Interval})}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({register, Node, Pid}, #state{watchers = Watchers0} = State) ->
    Pids0 = maps:get(Node, Watchers0, #{}),
    Pids =  case Pids0 of
                #{Pid := _Mon} -> Pids0;
                #{} -> Pids0#{Pid => erlang:monitor(process, Pid)}
            end,
    Watchers = maps:put(Node, Pids, Watchers0),
    ok = try_connect(Node),
    {noreply, State#state{watchers = Watchers}};
handle_cast({unregister, Node, Pid}, #state{watchers = Watchers0} = State) ->
    Watchers = case Watchers0 of
                   #{Node := Pids} ->
                       Watchers0#{Node => maps:remove(Pid, Pids)};
                   _ ->
                       Watchers0
               end,
    {noreply, State#state{watchers = Watchers}}.

handle_info(poll, #state{threshold = Th,
                         node_states = Prev,
                         watchers = Watchers} = State0) ->
    State = set_timer(State0),
    Probs = aten_sink:get_failure_probabilities(),
    {Up, Down} = analyse(Probs, Prev, Th),
    ok = notify(Watchers, Down, down),
    ok = notify(Watchers, Up, up),
    {noreply, State#state{node_states = Probs}};
handle_info({'DOWN', _Mon, process, Pid, _R},
            #state{watchers = Watchers0} = State) ->
    Watchers = maps:map(fun(_Node, Pids) ->
        maps:remove(Pid, Pids)
    end,
    Watchers0),
    {noreply, State#state{watchers = Watchers}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

notify(_Watchers, [], _Evt) ->
    ok;
notify(Watchers, [Node | Nodes], Evt) ->
    case Watchers of
        #{Node := Pids} ->
            maps:map(fun(Pid, _) -> Pid ! {node_event, Node, Evt} end, Pids);
        _ ->
            ok
    end,
    notify(Watchers, Nodes, Evt).

analyse_one(_Curr, undefined, _Thresh) ->
    up; %??
analyse_one(Curr, Prev, Thresh) when Prev < Thresh andalso Curr >= Thresh ->
    down;
analyse_one(Curr, Prev, Thresh) when Prev >= Thresh andalso Curr < Thresh ->
    up;
analyse_one(_Curr, _Prev, _Thresh) ->
    no_change.

analyse(Curr, Prev, Thresh) ->
    lists:foldl(fun ({Node, Sample}, {Up, Down} = Acc) ->
                        case analyse_one(Sample,
                                         maps:get(Node, Prev, undefined),
                                         Thresh) of
                            up ->
                                {[Node | Up], Down};
                            down ->
                                {Up, [Node | Down]};
                            no_change ->
                                Acc
                        end
                end, {[], []}, maps:to_list(Curr)).


set_timer(State) ->
    TRef = erlang:send_after(State#state.interval, self(), poll),
    State#state{tref = TRef}.

try_connect(Node) ->
    case is_connected(Node) of
        true -> ok;
        false ->
            _ = spawn(fun () -> net_kernel:connect_node(Node) end),
            ok
    end.

is_connected(Node) ->
    lists:member(Node, nodes()).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

analyse_test() ->
    Curr = #{n1 => 1.0,% down
             n2 => 0.1, % up
             n3 => 0.5 % no change
            },
    Prev = #{n1 => 0.2,% down
             n2 => 1.0, % up
             n3 => 0.4
            },

    {[n2], [n1]} = analyse(Curr, Prev, 0.98),
    ok.

analyse_one_test() ->
    Th = 0.99,
    up = analyse_one(0.0, undefined, Th),
    down = analyse_one(1.0, 0.0, Th),
    up = analyse_one(0.5, 1.0, Th),
    no_change = analyse_one(0.4, 0.5, Th),
    ok.

-endif.
