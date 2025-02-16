%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.
%%%
%%% OTP Supervisor for monitoring RAFT processes. Correctness of RAFT
%%% relies on the consistency of the signaling between the processes,
%%% this supervisor is configured to restart all RAFT processes
%%% when any of them exits abnormally.

-module(wa_raft_part_sup).
-compile(warn_missing_spec).
-author("hsun324@whatsapp.com").

-behaviour(supervisor).

-export([
    child_spec/1
]).

%% API
-export([
    start_link/2,
    stop/3,
    raft_sup/2
]).

%% Supervisor callbacks
-export([
    init/1
]).

-include_lib("kernel/include/logger.hrl").
-include("wa_raft.hrl").

-spec child_spec(wa_raft:args()) -> supervisor:child_spec().
child_spec(#{table := Table, partition := Partition} = RaftArgs) ->
    Name = raft_sup(Table, Partition),
    #{
        id => Name,
        start => {?MODULE, start_link, [Name, RaftArgs]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    }.

-spec start_link(atom(), [term()]) -> {ok, Pid :: pid()} | ignore | wa_raft:error().
start_link(Name, RaftSpec) ->
    supervisor:start_link({local, Name}, ?MODULE, [RaftSpec]).

-spec stop(Supervisor :: atom() | pid(), Table :: atom(), Partition :: pos_integer()) -> ok | {error, not_found}.
stop(Supervisor, Table, Partition) ->
    Name = raft_sup(Table, Partition),
    case supervisor:terminate_child(Supervisor, Name) of
        ok ->
            supervisor:delete_child(Supervisor, Name);
        Error ->
            ?LOG_WARNING("Failed to stop child ~p. Error ~p", [Name, Error], #{domain => [whatsapp, wa_raft]})
    end.

-spec init([wa_raft:args()]) -> {ok, {supervisor:sup_flags(), list(supervisor:child_spec())}}.
init([#{table := Table, partition := Partition} = Args0]) ->
    Counters = counters:new(?RAFT_NUMBER_OF_LOCAL_COUNTERS, [atomics]),
    Args1 = Args0#{counters => Counters},

    % Store the local counters for this partition in persitent_term
    % This value should change very rarely (only when this RAFT partition
    % breaches the max restart rate for this supervisor).
    persistent_term:put(?RAFT_LOCAL_COUNTERS_KEY(Table, Partition), Counters),

    StorageModule = application:get_env(?APP, raft_storage_module, wa_raft_ast),
    code:ensure_loaded(StorageModule),
    Modules0 = case erlang:function_exported(StorageModule, child_spec, 1) of
                   true ->
                       [StorageModule];
                   _ ->
                       []
               end,
    Modules = Modules0 ++ [
        wa_raft_catchup,
        wa_raft_acceptor,
        wa_raft_storage,
        wa_raft_log,
        wa_raft_server
    ],
    Specs = [M:child_spec(Args1) || M <- Modules],
    {ok, {#{strategy => one_for_all, intensity => 10, period => 1}, Specs}}.

-spec raft_sup(wa_raft:table(), wa_raft:partition()) -> atom().
raft_sup(Table, Partition) ->
    list_to_atom("raft_sup_" ++ atom_to_list(Table) ++ "_" ++ integer_to_list(Partition)).
