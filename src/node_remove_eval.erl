-module(node_remove_eval).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

-define(INITIAL_CLUSTER_SIZE, 1).
-define(MAX_NODES, 2).
-define(TEST_ITERATIONS, 100).
-define(DEVS(N), lists:concat(["dev", N, "@127.0.0.1"])).
-define(DEV(N), list_to_atom(?DEVS(N))).

-define(BUCKET, <<"eqctest">>).

-record(state, {
          ring,
          primary :: [integer()],
          others :: [integer()],
          path,
          written,
          active_handoffs :: [{integer(), integer(), integer()}]
         }).

riakcmd(Path, N, Cmd) ->
    io_lib:format("~s/dev/dev~b/bin/riak ~s", [Path, N, Cmd]).

gitcmd(Path, Cmd) ->
    io_lib:format("git --git-dir=\"~s/dev/.git\" --work-tree=\"~s/dev\" ~s",
                  [Path, Path, Cmd]).

run_git(Path, Cmd) ->
    %%?debugFmt("~p~n", [os:cmd(gitcmd(Path, Cmd))]).
    os:cmd(gitcmd(Path, Cmd)).

run_riak(N, Path, Cmd) ->
    %%?debugFmt("RR: ~p~n", [[N,Path,Cmd]]),
    %%?debugFmt("~p~n", [os:cmd(riakcmd(Path, N, Cmd))]).
    os:cmd(riakcmd(Path, N, Cmd)).

%% basic_test_() ->
%%     {timeout, 60000, fun basic/0}.

basic() ->
    ENode = 'eunit@127.0.0.1',
    Cookie = riak, 
    Path = "/Users/jtuple/basho/riak-working",
    [] = os:cmd("epmd -daemon"),
    net_kernel:start([ENode]),
    erlang:set_cookie(node(), Cookie),

    %% Stop nodes if already running
    run_riak(1, Path, "stop"),
    run_riak(2, Path, "stop"),
    run_riak(3, Path, "stop"),

    %% Reset nodes to base state
    run_git(Path, "status"),
    run_git(Path, "reset HEAD --hard"),
    run_git(Path, "clean -f"),
    run_git(Path, "status"),

    %% Start nodes
    run_riak(1, Path, "start"),
    run_riak(2, Path, "start"),
    run_riak(3, Path, "start"),

    %% Ensure nodes started
    ?debugFmt("~p~n", [net_adm:ping('dev1@127.0.0.1')]),
    ?debugFmt("~p~n", [net_adm:ping('dev2@127.0.0.1')]),
    ?debugFmt("~p~n", [net_adm:ping('dev3@127.0.0.1')]),

    ok.

go() ->
    [begin
         Path = "/Users/jtuple/basho/riak-working",
         %% Nodes = [1,2,3],
         Nodes = lists:seq(1,NC),
         restart_nodes(Path, Nodes),
         %% Remove gossip limit
         [rpc:call(?DEV(NN), application, set_env,
                   [riak_core, gossip_limit, {100000, 1000}]) || NN <- Nodes],
         [rpc:call(?DEV(NN), application, set_env,
                   [riak_core, vnode_inactivity_timeout, 1000]) || NN <- Nodes],
         join_cluster(Nodes),
         wait_until_no_pending_changes(Nodes),
         disable_handoff(Nodes),
         %% N = 1,
         leave(N),

         timer:sleep(2000),
         Node0 = ?DEV(hd(Nodes -- [N])),
         {ok, Ring} = rpc:call(Node0, riak_core_ring_manager, get_raw_ring, []),
         %% riak_core_ring:pretty_print(Ring, []),
         Pending = length(riak_core_ring:pending_changes(Ring)),
         io:format("~b/~b: ~b~n", [N, NC, Pending]),
         {NC, N, Pending}
     end || NC <- lists:seq(9,16),
            N  <- lists:seq(1,NC)].

disable_handoff(Nodes) ->
    [rpc:call(?DEV(N), application, set_env,
              [riak_core, handoff_concurrency, 0]) || N <- Nodes],
    [rpc:call(?DEV(N), application, set_env,
              [riak_core, forced_ownership_handoff, 0]) || N <- Nodes],
    [rpc:call(?DEV(N), application, set_env,
              [riak_core, vnode_inactivity_timeout, 999999]) || N <- Nodes],
    ok.

join_cluster(Nodes) ->
    [Node0|Others] = Nodes,
    [join(Node, Node0) || Node <- Others].

setup() ->
    ENode = 'eunit@127.0.0.1',
    Cookie = riak, 
    [] = os:cmd("epmd -daemon"),
    net_kernel:start([ENode]),
    erlang:set_cookie(node(), Cookie),
    ok.

cleanup(_) ->
    ok.

initial_state() ->
    Path = "/Users/jtuple/basho/riak-working",
    #state{primary=[],
           others=[],
           written=[],
           path=Path}.

%% g_initial_nodes() ->
%%     Nodes = lists:seq(1, ?MAX_NODES),
%%     ?LET(L, shuffle(Nodes), lists:split(?INITIAL_CLUSTER_SIZE, L)).

initial_cluster(Path, {Primary, Others}) ->
    Nodes = Primary ++ Others,

    try
        restart_nodes(Path, Nodes)
    catch
        X:Y ->
            ?debugFmt("~p~n", [{X,Y}])
    end,
    ok.

join(Node, PNode) ->
    %%R = rpc:call(?DEV(Node), riak_kv_console, join, [[?DEVS(PNode)]]),
    R = rpc:call(?DEV(Node), riak_core, join, [?DEV(PNode)]),
    %% ?debugFmt("~p~n", [R]),
    wait_until_ready(Node, 100),
    %% ?debugFmt("CHECK~n", []),
    %% timer:sleep(20000),
    %% ?debugFmt("Ready ~p~n", [?DEV(Node)]),
    ok.

leave(Node) ->
    R = rpc:call(?DEV(Node), riak_core, leave, []),
    %% ?debugFmt("L: ~p~n", [R]),
    ok.

restart_nodes(Path, Nodes) ->
    %%?debugFmt("node: ~p~ncookie: ~p~n", [node(), erlang:get_cookie()]),

    %% Stop nodes if already running
    %% [run_riak(N, Path, "stop") || N <- Nodes],
    %%rpc:pmap({?MODULE, run_riak}, [Path, "stop"], Nodes),
    pmap(fun(N) -> run_riak(N, Path, "stop") end, Nodes),
    %% ?debugFmt("Shutdown~n", []),

    %% Reset nodes to base state
    run_git(Path, "status"),
    run_git(Path, "reset HEAD --hard"),
    run_git(Path, "clean -fd"),
    run_git(Path, "status"),
    %% ?debugFmt("Reset~n", []),

    %% Start nodes
    %%[run_riak(N, Path, "start") || N <- Nodes],
    %%rpc:pmap({?MODULE, run_riak}, [Path, "start"], Nodes),
    pmap(fun(N) -> run_riak(N, Path, "start") end, Nodes),

    %% Ensure nodes started
    [ok = wait_for_node(N, 10) || N <- Nodes],

    %% %% Enable debug logging
    %% [rpc:call(?DEV(N), lager, set_loglevel, [lager_console_backend, debug]) || N <- Nodes],

    %% Ensure nodes are singleton clusters
    [ok = check_initial_node(N) || N <- Nodes],

    %% timer:sleep(2000),

    %% %% Enable probing / tracing
    %% Nodes2 = [?DEV(Node) || Node <- Nodes],
    %% ?debugFmt("Tracing: ~p~n", [Nodes2]),
    %% basho_probe_server:start_link(),
    %% [rpc:call(Node, basho_probe, install, [node()]) || Node <- Nodes2],
    %% basho_probe_server:trace_nodes(Nodes2),
    %% %% basho_probe_server:trace_call(riak_core_gossip, finish_handoff, 4),
    %% basho_probe_server:trace_call(riak_kv_vnode, perform_put, 3),
    %% basho_probe_server:start_tracing(),
    
    %% ?debugFmt("restarted~n", []),
    %% timer:sleep(1000),
    ok.

check_initial_node(N) ->
    Node = ?DEV(N),
    {ok, Ring} = rpc:call(Node, riak_core_ring_manager, get_raw_ring, []),
    Owners = lists:usort([Owner || {_Idx, Owner} <- riak_core_ring:all_owners(Ring)]),
    %% ?debugFmt("~p~n", [Owners]),
    ?assertEqual([Node], Owners),
    ok.
    
%% trace() ->
%%     Nodes2 = [?DEV(1), ?DEV(2), ?DEV(3)],
%%     ?debugFmt("Tracing: ~p~n", [Nodes2]),
%%     A = basho_probe_server:start_link(),
%%     B = [rpc:call(Node, basho_probe, install, [node()]) || Node <- Nodes2],
%%     C = basho_probe_server:trace_nodes(Nodes2),
%%     D = basho_probe_server:trace_call(riak_core_gossip, finish_handoff, 4),
%%     E = basho_probe_server:trace_call(riak_kv_vnode, perform_put, 3),
%%     F = basho_probe_server:start_tracing(),
%%     ?debugFmt("~p~n", [[A,B,C,D,E,F]]),
%%     timer:sleep(30000).

wait_for_node(N, Retry) ->
    %% ?debugFmt("net_adm:ping(~p)~n", [?DEV(N)]),
    case {Retry, net_adm:ping(?DEV(N))} of
        {_, pong} ->
            ok;
        {0, _} ->
            fail;
        {_, _R} ->
            %%?debugFmt("R: ~p~n", [R]),
            timer:sleep(500),
            wait_for_node(N, Retry-1)
    end.
    
wait_until_ready(N, Retry) ->
    Node = ?DEV(N),
    %% ?debugFmt("waitready: ~p~n", [Node]),
    case rpc:call(Node, riak_core_ring_manager, get_my_ring, []) of
        {ok, Ring} ->
            Pass = lists:member(Node, riak_core_ring:ready_members(Ring));
        _ ->
            Pass = false
    end,
    case {Retry, Pass} of
        {_, true} ->
            ok;
        {0, _} ->
            fail;
        _ ->
            timer:sleep(500),
            wait_until_ready(N, Retry-1)
    end.

wait_until_no_pending_changes(Nodes) ->
    F = fun(N) ->
                [rpc:call(?DEV(NN), riak_core_vnode_manager, force_handoffs, [])
                 || NN <- Nodes],
                Node = ?DEV(N),
                {ok, Ring} = rpc:call(Node, riak_core_ring_manager, get_raw_ring, []),
                riak_core_ring:pending_changes(Ring) =:= []
        end,
    [?assertEqual(ok, wait_until(Node, F, 600)) || Node <- Nodes],
    ok.

are_no_pending(N) ->
    Node = ?DEV(N),
    rpc:call(Node, riak_core_vnode_manager, force_handoffs, []),
    {ok, Ring} = rpc:call(Node, riak_core_ring_manager, get_raw_ring, []),
    riak_core_ring:pending_changes(Ring) =:= [].

wait_until(Node, Fun, Retry) ->
    Pass = Fun(Node),
    case {Retry, Pass} of
        {_, true} ->
            ok;
        {0, _} ->
            fail;
        _ ->
            timer:sleep(500),
            wait_until(Node, Fun, Retry-1)
    end.

pmap(F, L) ->
    Parent = self(),
    lists:foldl(
      fun(X, N) ->
              spawn(fun() ->
                            Parent ! {pmap, N, F(X)}
                    end),
              N+1
      end, 0, L),
    L2 = [receive {pmap, N, R} -> {N,R} end || _ <- L],
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    L3.

print_pending(PL) ->
    io:format("||"),
    [io:format("~b|", [N]) || {_,N,_} <- lists:ukeysort(2,PL)],
    print_pending(PL, 0),
    io:format("~n").

print_pending([], _) ->
    ok;
print_pending([{NC,_,Pending}|PS], LastNC) ->
    PendingP = Pending * 100 div 64,
    case NC of
        LastNC ->
            io:format("~b%|", [PendingP]);
        _ ->
            io:format("~n|~b|~b%|", [NC, PendingP])
    end,
    print_pending(PS, NC).


