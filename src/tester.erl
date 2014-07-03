-module(tester).

-compile(export_all).

-record(config,
        {
          test_module,
          test_procs_count,
          loops_count,
          sleep_time,
          message_size,
          report_path,
          start_opts,
          log_opts,
          log_path
        }).

async_run(ConfigPath) ->
    proc_lib:spawn_link(fun() -> run(ConfigPath) end).

run(ConfigPath) ->
    StartSnapshot = system_health_snapshot(),
    io:format("read config ... "),
    Config = read_config(ConfigPath),
    io:format("ok~n"),

    io:format("create message ... "),
    Message = make_message(Config),
    io:format("ok~n"),

    io:format("start logger ... "),
    LoggerData = start_logger(Config),
    io:format("ok~n"),

    StartTimer = timer(),

    io:format("run workers ..."),
    Workers = run_workers(Config, LoggerData, Message),
    io:format("ok~n"),

    io:format("wait workers ... ~n"),
    Report = yield(Workers, Config),
    io:format("all done, write report to: ~s~n", [Config#config.report_path]),

    ok = write_report(Report, StartTimer, StartSnapshot, Config),
    CowSay = os:cmd("sh -c \"cowsay 'Goodbye' 2>/dev/null || echo Goodbye\""),
    io:format("~s~n", [CowSay]),
    ok.

start_logger(Config = #config{test_module = LoggerModule}) ->
    LoggerModule:start(Config#config.log_path, Config#config.start_opts).

make_message(Config) ->
    erlang:list_to_binary(lists:duplicate(Config#config.message_size, 42)).

run_workers(Config, LoggerData, Message) ->
    run_workers(Config, LoggerData, Message, Config#config.test_procs_count).

run_workers(_Config, _LoggerData, _Message, EmptyCounter) when EmptyCounter =< 0 ->
    [];
run_workers(Config, LoggerData, Message, Counter) ->
    SelfPid = self(),
    Worker = proc_lib:spawn(?MODULE, test_worker, [SelfPid, Config, LoggerData, Message]),
    WorkerRef = erlang:monitor(process, Worker),
    [{Worker, WorkerRef} | run_workers(Config, LoggerData, Message, Counter - 1)].

test_worker(ReportPid, Config, LoggerData, Message) ->
    test_worker(ReportPid, Config, LoggerData, Message, Config#config.loops_count).

test_worker(ReportPid, Config, _LoggerData, _Message, EmptyCounter)
  when EmptyCounter =< 0->
    ReportPid ! {self(), {done, [{writed, Config#config.loops_count}]}};
test_worker(ReportPid, Config = #config{test_module = Module}, LoggerData, Message, Counter) ->
    ok = Module:log(Message, [{logger_data, LoggerData} | Config#config.log_opts]),
    timer:sleep(Config#config.sleep_time),
    test_worker(ReportPid, Config, LoggerData, Message, Counter - 1).

yield(Workers, _Config) ->
    element(1,
            lists:mapfoldl(
              fun({Worker, MonRef}, AccIn) ->
                      receive
                          {'DOWN', MonRef, process, Worker, Reason} when Reason =/= normal ->
                              io:format("Worker #~w down, reason: ~p~n", [AccIn, Reason]),
                              {{Worker, {exit, Reason}}, AccIn + 1};
                          {Worker, {done, Results}} ->
                              receive_one_mon(MonRef),
                              io:format("Worker #~w done~n", [AccIn]),
                              {{Worker, {done, Results}}, AccIn + 1}
                      end
              end,
              1,
              Workers)).

receive_one_mon(MonRef) ->
    receive
        {'DOWN', MonRef, process, _, _} ->
            ookay
    after 100 ->
            ok
    end.

write_report(Report, Timer, StartSnapshot, Config) ->
    AllTime = Timer(),
    MessagesWrited = Config#config.test_procs_count * Config#config.loops_count,
    MPS = MessagesWrited / (AllTime / 1000000),
    file:write_file(
      Config#config.report_path,
      io_lib:format(
        "=== Config ===~n~s~n"
        "=== Statistics ===~n"
        "Run time: ~.2f sec~n"
        "Messaged writed: ~w~n"
        "MPS: ~.2f~n~n"
        "=== Report ===~n~p~n"
        "=== System info on start ===~n~p~n"
        "=== System info on end ===~n~p~n",
        [
         format_config(Config),
         AllTime / 1000000,
         MessagesWrited,
         MPS,
         Report,
         StartSnapshot,
         system_health_snapshot()
        ])).

timer() ->
    StartTime = os:timestamp(),
    fun() ->
            timer:now_diff(os:timestamp(), StartTime)
    end.

read_config(ConfigFilename) ->
    {ok, Props} = file:consult(ConfigFilename),
    TestModule = exact_value(test_module, Props),
    ProcsCount = exact_value(test_procs_count, Props),
    SleepTime = exact_value(sleep_time, Props),
    MessageSize = exact_value(message_size, Props),
    ReportPath = exact_value(report_path, Props),
    LoopsCount = exact_value(loops_count, Props),

    TestModuleProps = exact_value(TestModule, Props),
    StartOpts = exact_value(start_opts, TestModuleProps),
    LogOpts = exact_value(log_opts, TestModuleProps),
    LogPath = exact_value(log_path, TestModuleProps),

    #config{
      test_module = TestModule,
      test_procs_count = ProcsCount,
      loops_count = LoopsCount,
      sleep_time = SleepTime,
      message_size = MessageSize,
      report_path = ReportPath,
      start_opts = StartOpts,
      log_opts = LogOpts,
      log_path = LogPath
     }.

print_config(Config) ->
    io:format(format_config(Config)).

format_config(Config) ->
    io_lib:format(
      " test_modue: ~s~n"
      "  start options: ~p~n"
      "  log options: ~p~n"
      " testers count: ~w~n"
      " loops count: ~w~n"
      " sleep time: ~w mcs~n"
      " message size: ~w bytes~n"
      " log path: ~s~n"
      " report path: ~s~n",
      [
       Config#config.test_module,
       Config#config.start_opts,
       Config#config.log_opts,
       Config#config.test_procs_count,
       Config#config.loops_count,
       Config#config.sleep_time,
       Config#config.message_size,
       Config#config.log_path,
       Config#config.report_path
      ]).

exact_value(Key, Proplist) ->
    case proplists:get_value(Key, Proplist) of
        undefined ->
            erlang:error({undefined, Key});
        Value ->
            Value
    end.

system_health_snapshot() ->
    Memory = erlang:memory(),

    PCInfo = processes_info(
               [
                {message_queue_len, 10},
                {total_heap_size, 1024 * 1024}
               ]),
    [
     {memory, Memory},
     {proc_info, PCInfo}
    ].

processes_info(Filters) ->
    lists:foldl(
      fun(Proc, AccIn) ->
              case erlang:process_info(Proc) of
                  undefined ->
                      AccIn;
                  ProcInfo ->
                      filter_proc_info({Proc, ProcInfo}, Filters, AccIn)
              end
      end,
      [],
      erlang:processes()).

filter_proc_info({Proc, Info}, Filters, AccIn) ->
    case lists:any(
           fun({K, V}) ->
                   case proplists:get_value(K, Info) of
                       undefined ->
                           false;
                       Value when Value > V ->
                           true;
                       _ ->
                           false
                   end
           end, Filters) of
        true ->
            [{Proc, Info} | AccIn];
        _ ->
            AccIn
    end.

write_not_empty_queues(LogDir) ->
    lists:foreach(
      fun(Proc) ->
              case erlang:process_info(Proc) of
                  undefined ->
                      ok;
                  ProcInfo ->
                      case proplists:get_value(message_queue_len, ProcInfo) of
                          0 ->
                              ok;
                          _ ->
                              Name = smart_pid_name(Proc),
                              FilenameBin = filename:join(LogDir, Name ++ ".bin"),
                              FilenameTxt = filename:join(LogDir, Name ++ ".txt"),
                              ok = file:write_file(FilenameBin, term_to_binary({Proc, ProcInfo})),
                              ok = file:write_file(FilenameTxt, io_lib:format("~p~n", [{Proc, ProcInfo}]))
                      end
              end
      end,
      erlang:processes()).

smart_pid_name(Proc) ->
    case erlang:process_info(Proc, registered_name) of
        {registered_name, Name} ->
            erlang:atom_to_list(Name);
        _ ->
            erlang:pid_to_list(Proc)
    end.

lager_info_loop(SleepTime) ->
    timer:apply_interval(SleepTime, ?MODULE, lager_info, []).

lager_info() ->
    X = (catch element(2, erlang:process_info(whereis(lager_event), message_queue_len))),
    case X of
        0 ->
            ok;
        _ ->
            io:format("lager_event messages count: ~w~n", [X])
    end.
             
