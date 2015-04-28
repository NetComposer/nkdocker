%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkDOCKER Management Server
-module(nkdocker_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/1, start/1, stop/1, cmd/5, data/3, finish/2, create_spec/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).
-export([refresh_fun/1]).
-export_type([cmd_opts/0]).

-include("nkdocker.hrl").

-type cmd_opts() :: 
    #{
        async => boolean(),
        force_new => boolean(),
        headers => [{binary(), binary}],
        redirect => string(),           % Send to file
        timeout => pos_integer(),       % Reply and closes connection if reached
        refresh => boolean()            % Automatic refresh
    }.

-define(CALL_TIMEOUT, 60000).
-define(CONN_TIMEOUT, 180000).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a docker connection
-spec start_link(nkdocker:conn_opts()) ->
    {ok, pid()} | {error, term()}.

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).


%% @doc Starts a docker connection
-spec start(nkdocker:conn_opts()) ->
    {ok, pid()} | {error, term()}.

start(Opts) ->
    gen_server:start(?MODULE, [Opts], []).


%% @doc Stops a docker connection
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Sends a message
%% Every connection has a timeout, so it will never block
-spec cmd(pid(), binary(), binary(), binary()|iolist()|map(), cmd_opts()) ->
    term().

cmd(Pid, Verb, Path, Body, Opts) ->
    % Path1 = <<"/v1.17", Path/binary>>,
    gen_server:call(Pid, {cmd, Verb, Path, Body, Opts}, ?CALL_TIMEOUT).


%% @doc Sends a in-message data
-spec data(pid(), reference(), iolist()) ->
    ok | {error, term()}.

data(Pid, Ref, Data) ->
    gen_server:call(Pid, {data, {self(), Ref}, Data}, ?CALL_TIMEOUT).


%% @doc Finished an asynchronous command
-spec finish(pid(), reference()) ->
    {ok, pid()} | {error, term()}.

finish(Pid, Ref) ->
    gen_server:call(Pid, {finish, {self(), Ref}}, ?CALL_TIMEOUT).


%% @doc Generates creation options
-spec create_spec(pid(), nkdocker:create_opts()) ->
    {ok, map()} | {error, term()}.

create_spec(Pid, Opts) ->
    {ok, Vsn} = gen_server:call(Pid, get_vsn, ?CALL_TIMEOUT),
    nkdocker_opts:create_spec(Vsn, Opts).

%% @private
refresh_fun(NkPort) ->
    % lager:debug("Refreshing connection"),
    case nkpacket_connection:send(NkPort, <<"\r\n">>) of
        ok -> true;
        _ -> false
    end.



%% ===================================================================
%% gen_server
%% ===================================================================


-record(cmd, {
    from :: {pid(), reference()},
    conn_pid :: pid(),
    conn_ref :: reference(),
    mode :: shared | exclusive | async | {redirect, file:io_device()},
    status = 0 :: integer(),
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary(),
    chunked :: boolean(),
    user_mon :: reference()
}).

-record(state, {
    conn :: nkpacket:raw_connection(),
    conn_opts :: map(),
    vsn :: binary(),
    cmds = [] :: [#cmd{}]
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([Opts]) ->
    process_flag(trap_exit, true),      %% Allow calls to terminate/2
    EnvConfig = application:get_env(nkdocker, conn_config, #{}),
    Opts1 = maps:merge(EnvConfig, Opts),
    Host = maps:get(host, Opts1, "127.0.0.1"),
    Port = maps:get(port, Opts1, 2375),
    Proto = maps:get(proto, Opts1, tcp),
    case nkpacket_dns:get_ips(nkdocker, Host) of
        [Ip] ->
            Conn = {nkdocker_protocol, Proto, Ip, Port},
            Opts2 = maps:with([certfile, keyfile, idle_timeout], Opts1),
            ConnOpts = Opts2#{
                monitor => self(), 
                user => {notify, self()}, 
                idle_timeout => ?CONN_TIMEOUT
            },
            lager:debug("Connecting to ~p, (~p)", [Conn, ConnOpts]),
            case nkpacket:connect({nkdocker, self()}, Conn, ConnOpts) of
                {ok, _} ->
                    State = #state{
                        conn = Conn,
                        conn_opts = ConnOpts,
                        cmds = []
                    },
                    case get_version(State) of
                        {ok, Vsn} when Vsn >= <<"1.17">> ->
                            {ok, State#state{vsn=Vsn}};
                        {ok, Vsn} ->
                            {stop, {invalid_docker_version, Vsn}};
                        {error, Error} ->
                            {stop, Error}
                    end;
                {error, Error} ->
                    {stop, {connection_error, Error}}
            end;
        _ ->
            {stop, invalid_host}
    end.


%% @private
-spec handle_call(term(), {pid(), reference()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({cmd, Verb, Path, Body, Opts}, From, State) ->
    try
        Opts1 = case Opts of
            #{redirect:=File} ->
                case file:open(nklib_util:to_list(File), [write, raw]) of
                    {ok, Port} -> Opts#{redirect:=Port};
                    {error, FileError} -> throw({could_not_open, File, FileError})
                end;
            _ ->
                Opts
        end,
        case send(Verb, Path, Body, Opts1, From, State) of
            {ok, State1} ->
                {noreply, State1};
            {error, Error} ->
                {stop, normal, {error, Error}, State}
        end
    catch
        throw:Throw -> {reply, {error, Throw}, State}
    end;

handle_call({data, UserFrom, Data}, _From, #state{cmds=Cmds}=State) ->
    case lists:keyfind(UserFrom, #cmd.from, Cmds) of
        #cmd{conn_pid=ConnPid} ->
            spawn(
                fun() -> 
                    case catch nkpacket_connection:send(ConnPid, Data) of
                        ok -> 
                            ok;
                        Error ->
                            lager:notice("NkDOCKER: Error sending user message: ~p",
                                         [Error]),
                            nkpacket_connection:stop(ConnPid, send_error)
                    end
                end),
            {reply, ok, State};
        false ->
            {reply, {error, unknown_ref}, State}
    end;

handle_call({finish, From}, _, #state{cmds=Cmds}=State) ->
    case lists:keyfind(From, #cmd.from, Cmds) of
        #cmd{mode=async}=Cmd ->
            State1 = do_stop(Cmd, {stop, normal}, State),
            {reply, ok, State1};
        _ ->
            {reply, {error, unknown_ref}, State}
    end;

handle_call(get_vsn, _From, #state{vsn=Vsn}=State) ->
    {reply, {ok, Vsn}, State};

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, normal, #state{}}.

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    nklib_util:gen_server_info(#state{}).

handle_info({nkdocker, {head, From, Status, Headers, Last}}, State) ->
    % lager:warning("Head: ~p, ~p, ~p", [Status, Headers, Last]),
    State1 = parse_head(From, Status, Headers, Last, State),
    {noreply, State1};

handle_info({nkdocker, {data, From, Data, Last}}, State) ->
    % lager:warning("Data: ~p", [Data]),
    State1 = parse_data(From, Data, Last, State),
    {noreply, State1};

% handle_info({timeout, _, {async, From, Refresh}}, #state{cmds=Cmds}=State) ->
%     case lists:keyfind(From, #cmd.from, Cmds) of
%         #cmd{conn_pid=ConnPid}=Cmd ->
%             spawn(fun() -> nkpacket_connection:send(ConnPid, <<"\r\n">>) end),
%             Cmd1 = Cmd#cmd{refresh=start_timer(From, Refresh)},
%             Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd1),
%             {noreply, State#state{cmds=Cmds1}};
%         false ->
%             {noreply, State}
%     end;

handle_info({'DOWN', MRef, process, _MPid, _Reason}, #state{cmds=Cmds}=State) ->
    case lists:keyfind(MRef, #cmd.conn_ref, Cmds) of
        #cmd{mode=async}=Cmd ->
            {noreply, do_stop(Cmd, {stop, connection_stopped}, State)};
        #cmd{mode={redirect, _}}=Cmd ->
            {noreply, do_stop(Cmd, {error, connection_stopped}, State)};
        #cmd{headers=Headers, body=Body}=Cmd ->
            case nklib_util:get_value(<<"content-type">>, Headers) of
                <<"application/vnd.docker.raw-stream">> ->
                    {noreply, do_stop(Cmd, {ok, Body}, State)};
                _ ->
                    {noreply, do_stop(Cmd, {error, connection_stopped}, State)}
            end;
        false ->
            case lists:keyfind(MRef, #cmd.user_mon, Cmds) of
                #cmd{}=Cmd ->
                    {noreply, do_stop(Cmd, none, State)};
                false ->
                    {noreply, State}
            end
    end;

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    nklib_util:gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    nklib_util:gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.



%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec get_version(#state{}) ->
    {ok, binary()} | {stop, term()}.

get_version(#state{conn=Conn, conn_opts=ConnOpts}) ->
    From = {self(), make_ref()},
    Msg = {
        http, 
        From,
        <<"GET">>, 
        <<"/version">>,
        [{<<"connection">>, <<"keep-alive">>}],
        <<>>
    },
    case nkpacket:send({nkdocker, self()}, Conn, Msg, ConnOpts) of
        {ok, _} ->
            case
                receive 
                    {nkdocker, {head, From, 200, _, false}} ->
                        receive
                            {nkdocker, {data, From, Data, true}} ->
                                catch jiffy:decode(Data, [return_maps])
                        after
                            5000 -> timeout
                        end
                after
                    5000 -> timeout
                end
            of

                #{<<"ApiVersion">>:=ApiVersion} ->
                    {ok, ApiVersion};
                timeout ->
                    {error, connect_timeout};
                Other ->
                    {error, {invalid_return, Other}}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec send(binary(), binary(), binary(), cmd_opts(), {pid(), reference()}, 
           #state{}) ->
    {ok, #state{}} | {error, term()}.

send(Method, Path, Body, Opts, From, State) ->
    #state{conn=Conn, conn_opts=ConnOpts, cmds=Cmds} = State,
    Mode = case Opts of
        #{async:=true} -> async;
        #{force_new:=true} -> exclusive;
        #{redirect:=Port} -> {redirect, Port};
        _ -> shared
    end,
    {Id, ConnOpts1, Hds1} = case Mode of
        shared -> {self(), ConnOpts, [{<<"connection">>, <<"keep-alive">>}]};
        _ -> {exclusive, ConnOpts#{force_new=>true}, []}
    end,
    Hds2 = case Opts of
        #{headers:=UserHeaders} -> Hds1 ++ UserHeaders;
        _ -> Hds1
    end,
    Msg = {http, From, Method, Path, Hds2, Body},
    ConnOpts2 = case Opts of
        #{timeout:=Timeout} -> ConnOpts1#{idle_timeout=>Timeout};
        #{idle_timeout:=Timeout} -> ConnOpts1#{idle_timeout=>Timeout};
        _ -> ConnOpts1
    end,
    ConnOpts3 = case Opts of
        #{refresh:=true} -> ConnOpts2#{refresh_fun=>fun refresh_fun/1};
        _ -> ConnOpts2
    end,
    lager:debug("NkDOCKER SEND: ~p ~p", [Msg, ConnOpts3]),
    case nkpacket:send({nkdocker, Id}, Conn, Msg, ConnOpts3) of
        {ok, NkPort} ->
            ConnPid = nkpacket:get_pid(NkPort),
            Cmd1 = #cmd{
                from = From, 
                conn_pid = ConnPid,
                conn_ref = erlang:monitor(process, ConnPid), 
                mode = Mode
            },
            Cmd2 = case Mode of
                async ->
                    UserMon = erlang:monitor(process, element(1, From)),
                    Cmd1#cmd{user_mon=UserMon};
                _ ->
                    Cmd1
            end,

            {ok, State#state{cmds=[Cmd2|Cmds]}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec parse_head({pid(), reference()}, pos_integer(), list(), boolean(), 
                 #state{}) ->
    #state{}.

parse_head(From, Status, Headers, true, #state{cmds=Cmds}=State) ->
    case lists:keyfind(From, #cmd.from, Cmds) of
        #cmd{mode=async}=Cmd ->
            do_stop(Cmd#cmd{status=Status, headers=Headers}, {stop, no_data}, State);
        #cmd{}=Cmd ->
            parse_cmd(Cmd#cmd{status=Status, headers=Headers}, State);
        false ->
            lager:warning("Received unexpected head!"),
            State
    end;

parse_head(From, Status, Headers, false, #state{cmds=Cmds}=State) ->
    Chunked = lists:member({<<"transfer-encoding">>, <<"chunked">>}, Headers),
    case lists:keyfind(From, #cmd.from, Cmds) of
        #cmd{mode=async, from={_, Ref}=From, conn_pid=ConnPid}=Cmd ->
            gen_server:reply(From, {ok, Ref, ConnPid}),
            Cmd1 = Cmd#cmd{status=Status, headers=Headers, body= <<>>, chunked=Chunked},
            Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd1),
            State#state{cmds=Cmds1};
        #cmd{}=Cmd ->
            Cmd1 = Cmd#cmd{status=Status, headers=Headers, body= <<>>, chunked=Chunked},
            Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd1),
            State#state{cmds=Cmds1};
        false ->
            lager:warning("Received unexpected head!"),
            State
    end.


%% @private
-spec parse_data({pid(), reference()}, binary(), boolean(), #state{}) ->
    #state{}.

parse_data(From, Data, Last, #state{cmds=Cmds}=State) ->
    case lists:keyfind(From, #cmd.from, Cmds) of
        #cmd{mode=async, body=Body}=Cmd ->
            Cmd1 = Cmd#cmd{body = << Body/binary, Data/binary >>},
            State1 = parse_async(Cmd1, State),
            case Last of
                true -> do_stop(Cmd, {stop, normal}, State1);
                false -> State1
            end;
        #cmd{mode={redirect, Port}}=Cmd ->
            case file:write(Port, Data) of
                ok when Last ->
                    parse_cmd(Cmd#cmd{body=Data}, State);
                ok ->
                    State;
                {error, _Error} ->
                    do_stop(Cmd, {error, write_error}, State)
            end;
        #cmd{body=Body, chunked=Chunked}=Cmd ->
            Data1 = case Data of
                <<${, _/binary>> when Chunked -> <<$,, Data/binary>>; 
                _ -> Data
            end,
            Cmd1 = Cmd#cmd{body = << Body/binary, Data1/binary >>},
            case Last of
                true ->
                    parse_cmd(Cmd1, State);
                false ->
                    Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd1),
                    State#state{cmds=Cmds1}
            end;
        false ->
            lager:warning("Received unexpected data!"),
            State
    end.


%% @private
-spec parse_async(#cmd{}, #state{}) ->
    #state{}.

parse_async(#cmd{from={Pid, Ref}=From}=Cmd, #state{cmds=Cmds}=State) ->
    case parse_body(Cmd) of
        {ok, Body, Rest} ->
            Pid ! {nkdocker, Ref, Body},
            Cmd1 = Cmd#cmd{body=Rest},
            Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd1),
            State#state{cmds=Cmds1};
        more ->
            Cmds1 = lists:keystore(From, #cmd.from, Cmds, Cmd),
            State#state{cmds=Cmds1};
        {error, Error} ->
            do_stop(Cmd, {stop, Error}, State)
    end.


%% @private
-spec parse_cmd(#cmd{}, #state{}) ->
    #state{}.

parse_cmd(#cmd{status=Status}=Cmd, State) 
          when Status==200; Status==201; Status==204 ->
    Reply = case parse_body(Cmd) of
        {ok, Body, _} -> {ok, Body};
        more -> {ok, <<>>};
        {error, Error} -> {error, Error}
    end,
    do_stop(Cmd, Reply, State);

parse_cmd(#cmd{status=Status, body=Body}=Cmd, State) ->
    Error = case Status of
        304 -> not_modified;
        400 -> bad_parameter;
        404 -> not_found;
        406 -> not_running;
        409 -> conflict;
        500 -> server_error;
        _ -> Status
    end,
    do_stop(Cmd, {error, {Error, Body}}, State).


%% @private
-spec parse_body(#cmd{}) ->
    more | {ok, term()} | {error, term()}.

parse_body(#cmd{body = <<>>}) ->
    more;

parse_body(#cmd{headers=Headers, mode=Mode, body=Body, chunked=Chunked}) ->
    case nklib_util:get_value(<<"content-type">>, Headers) of
        <<"application/json">> ->
            Body1 = case Body of
                <<$,, Rest/binary>> when Mode/=async, Chunked -> 
                    <<$[, Rest/binary, $]>>;
                _ -> 
                    Body
            end,
            case catch jiffy:decode(Body1, [return_maps]) of
                {'EXIT', _} ->
                    {error, {invalid_json, Body}};
                Obj ->
                    {ok, Obj, <<>>}
            end;
        <<"application/vnd.docker.raw-stream">> ->
            case Body of
                <<T, 0, 0, 0, Size:32, Rest/binary>> when T==0; T==1; T==2 ->
                    Type = case T of 0 -> stdin; 1 -> stdout; 2 -> stderr end,
                    case byte_size(Rest) of
                        Size -> 
                            {ok, {Type, Rest}, <<>>};
                        BinSize when BinSize < Size -> 
                            more;
                        _ -> 
                            {Msg, Rest2} = erlang:split_binary(Rest, Size),
                            {ok, {Type, Msg}, Rest2}
                    end;
                _ ->
                    {ok, Body, <<>>}
            end;
        _ ->
            {ok, Body, <<>>}
    end.


%% @private
-spec do_stop(#cmd{}, term(), #state{}) ->
    #state{}.

do_stop(Cmd, Msg, #state{cmds=Cmds}=State) ->
    #cmd{
        from = {Pid, Ref} = From, 
        conn_pid = ConnPid, 
        conn_ref = ConnRef,
        mode = Mode,
        user_mon = UserMon
    } = Cmd,
    case Mode of  
        async ->
            erlang:demonitor(ConnRef),
            erlang:demonitor(UserMon),
            nkpacket_connection:stop(ConnPid, normal),
            Pid ! {nkdocker, Ref, Msg};
        shared -> 
            gen_server:reply(From, Msg);
        exclusive -> 
            erlang:demonitor(ConnRef),
            nkpacket_connection:stop(ConnPid, normal),
            gen_server:reply(From, Msg);
        {redirect, Port} ->
            file:close(Port),
            erlang:demonitor(ConnRef),
            nkpacket_connection:stop(ConnPid, normal),
            gen_server:reply(From, Msg)
    end,
    Cmds1 = lists:keydelete(From, #cmd.from, Cmds),
    State#state{cmds=Cmds1}.


