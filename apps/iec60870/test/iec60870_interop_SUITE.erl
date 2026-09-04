%%% Wire-level interop test: our 104 server driven by `lib60870`'s real
%%% CS104 master implementation (<https://github.com/mz-automation/lib60870>),
%%% not a hand-rolled raw-socket client like the other `*_SUITE's — this is
%%% the docs/DESIGN.md phase 8 "interop test vs lib60870" item.
%%%
%%% `init_per_suite' fetches a pinned `lib60870' release (shallow git clone)
%%% into a local cache (`filename:basedir(user_cache, "iec60870_interop")',
%%% e.g. `~/.cache/iec60870_interop') and builds it with `cmake' the first
%%% time it's needed; later runs reuse that cache. `apps/iec60870/test/
%%% interop/master_driver.c' — a small CS104 master program written for this
%%% suite (one scenario per test case, chosen by argv, `RESULT: <scenario>
%%% ok|fail: <reason>' on stdout) — is then compiled against it into
%%% `priv_dir'.
%%%
%%% Any of that failing (no git/cmake/make/gcc, no network, a build error)
%%% is a clean `{skip, Reason}', not a test failure — `rebar3 ct' stays
%%% green offline; CI is expected to run these for real since it normally
%%% has both the toolchain and network egress to github.com.
-module(iec60870_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([interrogate/1, test_command/1, direct_command/1,
         select_before_operate/1, clock_sync/1]).

%% Callback module for the server under test: accepts every command (the
%% driver only ever addresses IOA 100), accepts clock sync.
-export([init/1, select/2, execute/2, clock_sync/3]).

-define(LIB60870_TAG, "v2.4.1").
-define(LIB60870_URL, "https://github.com/mz-automation/lib60870.git").

suite() ->
    [{timetrap, {seconds, 180}}].

all() ->
    [interrogate, test_command, direct_command, select_before_operate, clock_sync].

%%%===================================================================
%%% Setup
%%%===================================================================

init_per_suite(Config) ->
    case ensure_lib60870() of
        {ok, Lib} ->
            case build_driver(Config, Lib) of
                {ok, Driver} ->
                    {ok, _} = application:ensure_all_started(iec60870),
                    {ok, _} = iec60870:start_server(?MODULE, server_config()),
                    Port = iec60870_server:listener_port(?MODULE),
                    [{driver, Driver}, {port, Port} | Config];
                {error, Reason} ->
                    {skip, Reason}
            end;
        {error, Reason} ->
            {skip, Reason}
    end.

end_per_suite(_Config) ->
    iec60870:stop_server(?MODULE).

server_config() ->
    #{transport => {tcp, [{ip, {127, 0, 0, 1}}, {port, 0}]},
      common_addresses => [1],
      data_model => {iec60870_dm_ets, #{points => [
          {{1, 100}, #{type => m_sp_na_1, value => false}},
          {{1, 200}, #{type => m_me_nc_1, value => 3.5}}
      ]}},
      callback => {?MODULE, #{}}}.

init(_Args) -> {ok, #{}}.
select(_Command, State) -> {accept, State}.
execute(_Command, State) -> {ok, State}.
clock_sync(_Coa, _Time, State) -> {ok, State}.

%%%===================================================================
%%% Test cases — one per master_driver.c scenario
%%%===================================================================

interrogate(Config) -> run_scenario(Config, "interrogate").
test_command(Config) -> run_scenario(Config, "test_command").
direct_command(Config) -> run_scenario(Config, "direct_command").
select_before_operate(Config) -> run_scenario(Config, "select_before_operate").
clock_sync(Config) -> run_scenario(Config, "clock_sync").

run_scenario(Config, Scenario) ->
    Driver = ?config(driver, Config),
    Port = ?config(port, Config),
    Args = ["127.0.0.1", integer_to_list(Port), Scenario],
    {Status, Output} = exec(Driver, Args, 15000),
    ct:pal("~s (exit ~p):~n~s", [Scenario, Status, Output]),
    Expect = list_to_binary("RESULT: " ++ Scenario ++ " ok"),
    ?assertEqual(0, Status),
    ?assert(binary:match(Output, Expect) =/= nomatch).

%%%===================================================================
%%% lib60870 fetch + build (cached)
%%%===================================================================

ensure_lib60870() ->
    CacheDir = filename:basedir(user_cache, "iec60870_interop"),
    RepoDir = filename:join(CacheDir, "lib60870-" ++ ?LIB60870_TAG),
    CDir = filename:join(RepoDir, "lib60870-C"),
    BuildDir = filename:join(CDir, "build"),
    Archive = filename:join([BuildDir, "src", "liblib60870.a"]),
    Lib = #{c_dir => CDir, archive => Archive},
    case filelib:is_regular(Archive) of
        true -> {ok, Lib};
        false -> fetch_and_build(CacheDir, RepoDir, CDir, BuildDir, Lib)
    end.

fetch_and_build(CacheDir, RepoDir, CDir, BuildDir, Lib) ->
    case missing_tool() of
        {missing, Tool} ->
            {error, "lib60870 not cached locally and '" ++ Tool ++
                    "' is not on PATH; interop suite skipped"};
        ok ->
            ok = filelib:ensure_dir(filename:join(CacheDir, ".")),
            _ = file:del_dir_r(RepoDir),
            case run_cmd("git", ["clone", "--depth", "1", "--branch",
                                 ?LIB60870_TAG, ?LIB60870_URL, RepoDir], 120000) of
                {0, _} -> configure_and_build(CDir, BuildDir, Lib);
                {_, Out} -> {error, "git clone of lib60870 failed (no network?): " ++ tidy(Out)}
            end
    end.

configure_and_build(CDir, BuildDir, #{archive := Archive} = Lib) ->
    Jobs = integer_to_list(max(1, erlang:system_info(schedulers_online))),
    case run_cmd("cmake", ["-S", CDir, "-B", BuildDir,
                           "-DCMAKE_BUILD_TYPE=Release"], 60000) of
        {0, _} ->
            case run_cmd("cmake", ["--build", BuildDir, "-j", Jobs], 120000) of
                {0, _} ->
                    case filelib:is_regular(Archive) of
                        true -> {ok, Lib};
                        false -> {error, "lib60870 built but liblib60870.a is missing"}
                    end;
                {_, Out} -> {error, "lib60870 build failed: " ++ tidy(Out)}
            end;
        {_, Out} -> {error, "cmake configure of lib60870 failed: " ++ tidy(Out)}
    end.

missing_tool() ->
    missing_tool(["git", "cmake", "make", "gcc"]).

missing_tool([]) -> ok;
missing_tool([Tool | Rest]) ->
    case os:find_executable(Tool) of
        false -> {missing, Tool};
        _ -> missing_tool(Rest)
    end.

%%%===================================================================
%%% Driver compile
%%%===================================================================

build_driver(Config, #{c_dir := CDir, archive := Archive}) ->
    SuiteDir = filename:dirname(code:which(?MODULE)),
    Source = filename:join([SuiteDir, "interop", "master_driver.c"]),
    Out = filename:join(?config(priv_dir, Config), "master_driver"),
    Includes = [filename:join([CDir, "config"]),
                filename:join([CDir, "src", "file-service"]),
                filename:join([CDir, "src", "inc", "api"]),
                filename:join([CDir, "src", "inc", "internal"]),
                filename:join([CDir, "src", "common", "inc"]),
                filename:join([CDir, "src", "hal", "inc"])],
    IncludeArgs = lists:append([["-I", I] || I <- Includes]),
    Args = ["-O2", "-Wall"] ++ IncludeArgs ++
           [Source, Archive, "-lpthread", "-o", Out],
    case run_cmd("gcc", Args, 30000) of
        {0, _} -> {ok, Out};
        {_, Out2} -> {error, "failed to compile the interop driver: " ++ tidy(Out2)}
    end.

%%%===================================================================
%%% Process helpers
%%%===================================================================

run_cmd(Exe, Args, Timeout) ->
    case os:find_executable(Exe) of
        false -> {127, list_to_binary("executable not found: " ++ Exe)};
        Path -> exec(Path, Args, Timeout)
    end.

exec(Path, Args, Timeout) ->
    Port = open_port({spawn_executable, Path},
                      [{args, Args}, exit_status, stderr_to_stdout, binary]),
    collect(Port, <<>>, Timeout).

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>, Timeout);
        {Port, {exit_status, Status}} -> {Status, Acc}
    after Timeout ->
        catch port_close(Port),
        {timeout, Acc}
    end.

tidy(Bin) -> binary_to_list(Bin).
