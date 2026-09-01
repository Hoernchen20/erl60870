%%% @doc Instance name registry.
%%%
%%% Maps a user-supplied instance name to the pid of that instance's top
%%% supervisor. Also implements the `{via, Module, Name}' callbacks
%%% (`register_name/2', `unregister_name/1', `whereis_name/1', `send/2') so an
%%% instance can be addressed with a standard OTP name spec.
%%%
%%% Also binds async-command references to their owning `iec60870_server_ctl'
%%% (docs/DESIGN.md section 7), under the tagged key `{command, Ref}' so it
%%% cannot collide with an instance name — `iec60870_server:command_result/2'
%%% is handed only a `reference()' and needs to find the right server.
%%%
%%% Lookups read the ETS table directly and take no lock. Registration and
%%% deregistration are serialised through the owning `gen_server', which also
%%% monitors registered pids and drops their entries when they die (a crashed
%%% `server_ctl' drops its command bindings the same way a crashed instance
%%% supervisor drops its name).
-module(iec60870_registry).
-behaviour(gen_server).

-export([start_link/0]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2, names/0]).
-export([bind_command/2, command_owner/1, unbind_command/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-define(TAB, ?MODULE).

-type name() :: term().
-export_type([name/0]).

-record(state, {}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Bind `Name' to `Pid'. Returns `no' if `Name' is already bound.
-spec register_name(name(), pid()) -> yes | no.
register_name(Name, Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {register, Name, Pid}).

-spec unregister_name(name()) -> ok.
unregister_name(Name) ->
    gen_server:call(?MODULE, {unregister, Name}).

-spec whereis_name(name()) -> pid() | undefined.
whereis_name(Name) ->
    try ets:lookup(?TAB, Name) of
        [{Name, Pid}] -> Pid;
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

-spec send(name(), term()) -> pid().
send(Name, Msg) ->
    case whereis_name(Name) of
        undefined -> exit({badarg, {Name, Msg}});
        Pid -> Pid ! Msg, Pid
    end.

%% @doc All current bindings — for debugging and tests.
-spec names() -> [{name(), pid()}].
names() ->
    ets:tab2list(?TAB).

%% @doc Bind an async-command reference to the `server_ctl' pid that issued
%% it, for {@link command_owner/1} to find later.
-spec bind_command(reference(), pid()) -> ok.
bind_command(Ref, Pid) when is_reference(Ref), is_pid(Pid) ->
    gen_server:call(?MODULE, {bind_command, Ref, Pid}).

%% @doc The `server_ctl' pid a command reference was bound to, or `undefined'
%% (never bound, already resolved, or its server is gone).
-spec command_owner(reference()) -> pid() | undefined.
command_owner(Ref) when is_reference(Ref) ->
    try ets:lookup(?TAB, {command, Ref}) of
        [{_, Pid}] -> Pid;
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

%% @doc Drop a command-reference binding once it is resolved.
-spec unbind_command(reference()) -> ok.
unbind_command(Ref) when is_reference(Ref) ->
    gen_server:call(?MODULE, {unbind_command, Ref}).

%%% gen_server

-spec init([]) -> {ok, #state{}}.
init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({register, Name, Pid}, _From, State) ->
    case ets:member(?TAB, Name) of
        false ->
            _ = monitor(process, Pid),
            true = ets:insert_new(?TAB, {Name, Pid}),
            {reply, yes, State};
        true ->
            {reply, no, State}
    end;
handle_call({unregister, Name}, _From, State) ->
    _ = ets:delete(?TAB, Name),
    {reply, ok, State};
handle_call({bind_command, Ref, Pid}, _From, State) ->
    _ = monitor(process, Pid),
    true = ets:insert(?TAB, {{command, Ref}, Pid}),
    {reply, ok, State};
handle_call({unbind_command, Ref}, _From, State) ->
    _ = ets:delete(?TAB, {command, Ref}),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State) ->
    _ = ets:match_delete(?TAB, {'_', Pid}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
