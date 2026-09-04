-module(iec60870).
-moduledoc """
Top-level convenience API for library-managed servers (`docs/DESIGN.md`
section 9).

`start_server/2` grafts a server subtree under the library's
`iec60870_instances_sup` and registers its name with `m:iec60870_registry`;
`stop_server/1` tears it back down. To embed a server in your own supervision
tree use `iec60870_server:start_link/1` instead.
""".

-export([start_server/2, stop_server/1, which_servers/0]).

-doc """
Start a server named `Name` from the `docs/DESIGN.md` section 9 config map.
`Name` is then usable as the first argument to the `m:iec60870_server` API.
""".
-spec start_server(iec60870_registry:name(), map()) ->
        {ok, pid()} | {error, term()}.
start_server(Name, Config) when is_map(Config) ->
    ChildSpec = #{id => Name,
                  start => {iec60870_server_sup, start_link,
                            [Name, Config#{name => Name}]},
                  restart => transient,
                  type => supervisor,
                  shutdown => infinity,
                  modules => [iec60870_server_sup]},
    case supervisor:start_child(iec60870_instances_sup, ChildSpec) of
        {ok, Pid} ->
            case iec60870_registry:register_name(Name, Pid) of
                yes ->
                    {ok, Pid};
                no ->
                    _ = supervisor:terminate_child(iec60870_instances_sup, Name),
                    _ = supervisor:delete_child(iec60870_instances_sup, Name),
                    {error, {already_registered, Name}}
            end;
        {error, already_present} ->
            _ = supervisor:delete_child(iec60870_instances_sup, Name),
            start_server(Name, Config);
        {error, _} = Error ->
            Error
    end.

-doc "Stop and forget a server started with `start_server/2`.".
-spec stop_server(iec60870_registry:name()) -> ok.
stop_server(Name) ->
    _ = supervisor:terminate_child(iec60870_instances_sup, Name),
    _ = supervisor:delete_child(iec60870_instances_sup, Name),
    _ = iec60870_registry:unregister_name(Name),
    ok.

-doc "Every currently registered library-managed server.".
-spec which_servers() -> [{iec60870_registry:name(), pid()}].
which_servers() ->
    iec60870_registry:names().
