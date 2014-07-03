-module(disk_log_logger).

-compile(export_all).

-define(LOG_NAME, test_log).

start(Path, Opts) ->
    Size = proplists:get_value(size, Opts, infinity),
    Format = proplists:get_value(format, Opts, external),

    {ok, _} = disk_log:open([{name, ?LOG_NAME}, {size, Size}, {format, Format}, {file, Path}]),
    [{format, Format}].

log(Message, Opts) ->
    MessageOut = erlang:iolist_to_binary([io_lib:format("~p: ", [{date(), time()}]), Message, "\n"]),
    ok = apply(disk_log, log_function(Opts), [?LOG_NAME, MessageOut]).

log_function(Opts) ->
    case {proplists:get_value(format, Opts, external), proplists:get_value(sync, Opts, false)} of
        {internal, true} ->
            log;
        {internal, false} ->
            alog;
        {external, true} ->
            blog;
        {external, false} ->
            balog
    end.

