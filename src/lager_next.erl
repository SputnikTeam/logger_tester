-module (lager_next).

-export ([
    start/0,
    start/2,
    log/2
]).

-type proplist() :: [proplists:property()].

-spec start() -> ok.
start() ->
    start("default.log", [{level, debug}]).

-spec start(LogFilename :: string(), Options :: proplist()) -> ok.
start(LogFilename, Options) ->
    ok = lager:start(),
    {ok, _} = start_lager_handler(LogFilename, Options),
    ok.

-spec log(Text :: binary(), Options :: proplist()) -> ok.
log(Text, Options) ->
    lager:info(Options, Text, []).

start_lager_handler(File, Options) ->
    LogFileConfig = lists:keystore(file, 1, Options, {file, File}),
    supervisor:start_child(lager_handler_watcher_sup, [
        lager_event,
        {lager_file_backend, File},
        LogFileConfig
    ]).
