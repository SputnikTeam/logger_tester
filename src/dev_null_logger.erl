-module(dev_null_logger).

-compile(export_all).

start(_Path, _Opts) ->
    ookay.

log(_Message, _Opts) ->
    ok.

