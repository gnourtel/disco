-module(disco_worker).
-behaviour(gen_server).

-export([start_link_remote/3,
         start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         jobhome/1,
         event/3]).

-include("disco.hrl").

-record(state, {master :: node(),
                task :: task(),
                port :: none | port(),
                worker_send :: pid(),
                error_output :: boolean(),
                buffer :: binary(),
                parser :: worker_protocol:state(),
                runtime :: worker_runtime:state(),
                throttle :: worker_throttle:state()}).
-type state() :: #state{}.

-define(JOBHOME_TIMEOUT, 5 * 60 * 1000).
-define(PID_TIMEOUT, 30 * 1000).
-define(ERROR_TIMEOUT, 10 * 1000).
-define(MESSAGE_TIMEOUT, 30 * 1000).
-define(MAX_ERROR_BUFFER_SIZE, 100 * 1024).

-spec start_link_remote(nonempty_string(), pid(), task()) -> no_return().
start_link_remote(Host, NodeMon, Task) ->
    Node = disco:slave_node(Host),
    wait_until_node_ready(NodeMon),
    spawn_link(Node, disco_worker, start_link, [{self(), node(), Task}]),
    process_flag(trap_exit, true),
    receive
        ok -> ok;
        {'EXIT', _, Reason} ->
            exit({error, Reason});
        _ ->
            exit({error, "Internal server error: invalid_reply"})
    after 60000 ->
            exit({error, "Worker did not start in 60s"})
    end,
    wait_for_exit().

-spec wait_until_node_ready(pid()) -> 'ok'.
wait_until_node_ready(NodeMon) ->
    NodeMon ! {is_ready, self()},
    receive
        node_ready -> ok
    after 30000 ->
        exit({error, "Node unavailable"})
    end.

-spec wait_for_exit() -> no_return().
wait_for_exit() ->
    receive
        {'EXIT', _, Reason} ->
            exit(Reason)
    end.

-spec start_link({pid(), node(), task()}) -> no_return().
start_link({Parent, Master, Task}) ->
    process_flag(trap_exit, true),
    {ok, Server} = gen_server:start_link(disco_worker, {Master, Task}, []),
    gen_server:cast(Server, start),
    Parent ! ok,
    wait_for_exit().

init({Master, Task}) ->
    % Note! Worker is killed implicitely by killing its job_coordinator
    % which should be noticed by the monitor below. If the DOWN message
    % gets lost, e.g. due to temporary network partitioning, the worker
    % becomes a zombie.
    erlang:monitor(process, Task#task.from),
    {ok,
     #state{master = Master,
            task = Task,
            port = none,
            buffer = <<>>,
            error_output = false,
            parser = worker_protocol:init(),
            runtime = worker_runtime:init(Task, Master),
            throttle = worker_throttle:init()}
    }.

handle_cast(start, #state{task = Task, master = Master} = State) ->
    JobName = Task#task.jobname,
    Fun = fun() -> make_jobhome(JobName, Master) end,
    case catch gen_server:call(lock_server,
                               {wait, JobName, Fun}, ?JOBHOME_TIMEOUT) of
        ok ->
            gen_server:cast(self(), work),
            {noreply, State};
        {error, killed} ->
            {stop, {shutdown, {error, "Job pack extraction timeout"}}, State};
        {'EXIT', {timeout, _}} ->
            {stop, {shutdown, {error, "Job initialization timeout"}}, State}
    end;

handle_cast(work, #state{task = Task, port = none} = State) ->
    JobHome = jobhome(Task#task.jobname),
    Worker = filename:join(JobHome, binary_to_list(Task#task.worker)),
    Command = "nice -n 19 " ++ Worker,
    Options = [{cd, JobHome},
               stream,
               binary,
               exit_status,
               use_stdio,
               stderr_to_stdout,
               {env, Task#task.jobenvs}],
    Port = open_port({spawn, Command}, Options),
    SendPid = spawn_link(fun() -> worker_send(Port) end),
    {noreply, State#state{port = Port, worker_send = SendPid}, ?PID_TIMEOUT}.

handle_info({_Port, {data, Data}},
            #state{error_output = true, buffer = Buffer} = State)
            when size(Buffer) < ?MAX_ERROR_BUFFER_SIZE ->
    Buffer1 = <<(State#state.buffer)/binary, Data/binary>>,
    {noreply, State#state{buffer = Buffer1}, ?ERROR_TIMEOUT};

handle_info({_Port, {data, _Data}}, #state{error_output = true} = State) ->
    exit_on_error(State);

handle_info({_Port, {data, Data}}, S) ->
    update(S#state{buffer = <<(S#state.buffer)/binary, Data/binary>>});

handle_info(timeout, #state{error_output = false} = S) ->
    case worker_runtime:get_pid(S#state.runtime) of
        none ->
            warning("Worker did not send its PID in 30 seconds", S);
        _ ->
            warning("Worker stuck in the middle of a message", S)
    end,
    exit_on_error(S);

handle_info(timeout, S) ->
    warning("Worker did not exit properly after error", S),
    exit_on_error(S);

handle_info({_Port, {exit_status, Code}}, S) ->
    warning(["Worker crashed! (exit code: ", integer_to_list(Code), ")"], S),
    exit_on_error(S);

handle_info({'DOWN', _, _, _, Info}, State) ->
    {stop, {shutdown, {fatal, Info}}, State}.

handle_call(_Req, _From, State) ->
    {noreply, State}.

terminate(_Reason, S) ->
    case worker_runtime:get_pid(S#state.runtime) of
        none ->
            warning("PID unknown: worker could not be killed", S);
        Pid ->
            PidStr = integer_to_list(Pid),
            % Kill child processes of the worker process
            os:cmd(["pkill -9 -P ", PidStr]),
            % Kill the worker process
            os:cmd(["kill -9 ",  PidStr])
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec update(state()) -> {'noreply', state()} | {'stop', term(), state()}.
% Note that size(Buffer) =:= 0 is here to avoid binary matching
% which would force expensive copying of Buffer. See
% http://www.erlang.org/doc/efficiency_guide/binaryhandling.html
update(#state{buffer = Buffer} = S) when size(Buffer) =:= 0 ->
    {noreply, S};

update(S) ->
    case worker_protocol:parse(S#state.buffer, S#state.parser) of
        {ok, Request, Buffer, PState} ->
            S1 = S#state{buffer = Buffer},
            case catch worker_runtime:handle(Request, S#state.runtime) of
                {ok, Reply, RState} ->
                    case worker_throttle:handle(S#state.throttle) of
                        {ok, Delay, TState} ->
                            S#state.worker_send ! {Reply, Delay},
                            update(S1#state{parser = PState,
                                            runtime = RState,
                                            throttle = TState});
                        {error, Msg} ->
                            warning(Msg, S1),
                            exit_on_error(fatal, S1)
                    end;
                {stop, Ret} ->
                    {stop, {shutdown, Ret}, S};
                {error, {Type, Msg}} ->
                    warning(Msg, S1),
                    exit_on_error(Type, S1);
                {'EXIT', Reason} ->
                    warning(io_lib:format("~p", [Reason]), S1),
                    exit_on_error(error, S1)
            end;
        {cont, Buffer, PState} ->
            {noreply, S#state{buffer = Buffer, parser = PState}, ?MESSAGE_TIMEOUT};
        {error, Type} ->
            warning(["Could not parse worker event: ", atom_to_list(Type)], S),
            handle_info({none, {data, <<>>}}, S#state{error_output = true})
    end.

-spec worker_send(port()) -> no_return().
worker_send(Port) ->
    receive
        {{MsgName, Payload}, Delay} ->
            timer:sleep(Delay),
            Type = list_to_binary(MsgName),
            Body = list_to_binary(mochijson2:encode(Payload)),
            Length = list_to_binary(integer_to_list(size(Body))),
            Msg = <<Type/binary, " ", Length/binary, " ", Body/binary, "\n">>,
            port_command(Port, Msg),
            worker_send(Port)
    end.

-spec make_jobhome(nonempty_string(), node()) -> 'ok'.
make_jobhome(JobName, Master) ->
    JobHome = jobhome(JobName),
    case jobpack:extracted(JobHome) of
        true ->
            ok;
        false ->
            disco:make_dir(JobHome),
            JobPack =
                case jobpack:exists(JobHome) of
                    true ->
                        jobpack:read(JobHome);
                    false ->
                        {ok, JobPackSrc} =
                            disco_server:get_worker_jobpack(Master, JobName),
                        {ok, _JobFile} = jobpack:copy(JobPackSrc, JobHome),
                        jobpack:read(JobHome)
                end,
            jobpack:extract(JobPack, JobHome)
    end.

-spec jobhome(nonempty_string()) -> nonempty_string().
jobhome(JobName) ->
    Home = filename:join(disco:get_setting("DISCO_DATA"), disco:host(node())),
    disco:jobhome(JobName, Home).

warning(Msg, #state{master = Master, task = Task}) ->
    event({<<"WARNING">>, iolist_to_binary(Msg)}, Task, Master).

event(Event, Task, Master) ->
    Host = disco:host(node()),
    event_server:task_event(Task, Event, {}, Host, {event_server, Master}).

exit_on_error(S) ->
    exit_on_error(error, S).

exit_on_error(Type, #state{buffer = <<>>} = S) ->
    {stop, {shutdown, {Type, "Worker died without output"}}, S};

exit_on_error(Type, #state{buffer = Buffer} = S)
              when size(Buffer) > ?MAX_ERROR_BUFFER_SIZE ->
    <<Buffer1:(?MAX_ERROR_BUFFER_SIZE - 3)/binary, _/binary>> = Buffer,
    exit_on_error(Type, S#state{buffer = <<Buffer1/binary, "...">>});

exit_on_error(Type, #state{buffer = Buffer} = S) ->
    Msg = ["Worker died. Last words:\n", Buffer],
    {stop, {shutdown, {Type, Msg}}, S}.

