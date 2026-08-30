%%% @doc Instance name registry.
%%%
%%% Maps a user-supplied instance name to the pid of that instance's top
%%% supervisor. Also implements the `{via, Module, Name}' callbacks
%%% (`register_name/2', `unregister_name/1', `whereis_name/1', `send/2') so an
%%% instance can be addressed with a standard OTP name spec.
%%%
%%% Lookups read the ETS table directly and take no lock. Registration and
%%% deregistration are serialised through the owning `gen_server', which also
%%% monitors registered pids and drops their entries when they die.
-module(iec60870_registry).
-behaviour(gen_server).

-export([start_link/0]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2, names/0]).
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
