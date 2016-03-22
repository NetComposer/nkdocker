%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(nkdocker_monitor).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([register/1, register/2, unregister/1, unregister/2, get_docker/1]).
-export([get_containers/1, get_container/2, get_all/0]).
-export([start_link/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, notify/0]).

-define(LLOG(Type, Txt, Args), lager:Type("NkDOCKER Monitor "++Txt, Args)).

-define(UPDATE_TIME, 10000).

-callback nkdocker_notify(id(), notify()) ->
    ok.

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: {inet:ip_address(), inet:port()}.

-type notify() ::
    {docker, {Id::binary(), Status::atom(), From::binary(), Time::integer()}} |
    {stats, {Id::binary(), Data::binary()}}  |
    {start, {Name::binary(), Id::binary(), Labels::map()}} |
    {stop, {Name::binary(), Id::binary(), Labels::map()}}.

-type data() ::
    #{
        name => binary(),
        labels => map(),
        data => map(),          % inspect resutl
        stats => map()
    }.




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Equivalent to register(CallBack, #{})
-spec register(module()) ->
    {ok, id()} | {error, term()}.

register(CallBack) ->
    nkdocker_monitor:register(CallBack, #{}).


%% @doc Registers a server to listen to docker events
%% For each new event, Callback:nkdocker_notify(id(), event()) will be called
%% The first caller for a specific ip and port daemon will start the server
-spec register(module(), nkdocker:conn_opts()) ->
    {ok, id()} | {error, term()}.

register(CallBack, Opts) ->
    case find(Opts) of
        {ok, Id, none} ->
            case nkdocker_sup:start_monitor(Id, CallBack, Opts) of
                {ok, _Pid} ->
                    {ok, Id};
                {error, Error} ->
                    {error, Error}
            end;
        {ok, _Id, Pid} ->
            gen_server:call(Pid, {register, CallBack});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Equivalent to runegister(CallBack, #{})
-spec unregister(module()) ->
    ok | {error, term()}.

unregister(CallBack) ->
    unregister(CallBack, #{}).


%% @doc Unregisters a callback
%% After the last callback is unregistered, the server stops
unregister(Callback, Opts) ->
    case find(Opts) of
        {ok, _Id, none} ->
            ok;
        {ok, _Id, Pid} ->
            gen_server:cast(Pid, {unregister, Callback});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Get the docker server pid
-spec get_docker(id()) ->
    {ok, pid()} | error.

get_docker(Id) ->
    case nklib_proc:values({?MODULE, Id}) of
        [] ->
            error;
        [{DockerPid, _Pid}] ->
            {ok, DockerPid}
    end.


%% @doc Get the docker server pid
-spec get_containers(id()) ->
    {ok, #{binary() => data()}} | error.

get_containers(Id) ->
    case nklib_proc:values({?MODULE, Id}) of
        [] ->
            error;
        [{_DockerPid, Pid}] ->
            nklib_util:call(Pid, get_containers)
    end.


%% @doc Get the docker server pid
-spec get_container(id(), binary()) ->
    {ok, data()} | error.

get_container(Id, UUID) ->
    case nklib_proc:values({?MODULE, Id}) of
        [] ->
            error;
        [{_DockerPid, Pid}] ->
            nklib_util:call(Pid, {get_container, nklib_util:to_binary(UUID)})
    end.


%% @doc Gets all started monitors
-spec get_all() ->
    [{id(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).


%% @private
start_link(Id, CallBack, Opts) ->
    gen_server:start_link(?MODULE, [Id, CallBack, Opts], []).


%% @private
find(Opts) ->
    case nkdocker_server:get_conn(Opts) of
        {ok, {Ip, #{port:=Port}}} ->
            Id = {Ip, Port},
            case nklib_proc:values({?MODULE, Id}) of
                [] ->
                    {ok, Id, none};
                [{_, Pid}] ->
                    {ok, Id, Pid}
            end;
        {error, Error} ->
            {error, Error}
    end.


% ===================================================================
%% gen_server behaviour
%% ===================================================================

-record(state, {
    id :: id(),
    server :: pid(),
    event_ref :: reference(),
    regs = [] :: [module()],
    time = 0 :: integer(),
    conts = #{} :: #{binary() => map()},
    stats_refs = #{} :: #{reference() => binary()}
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([Id, CallBack, Opts]) ->
    case nkdocker_server:start_link(Opts) of
        {ok, Pid} ->
            monitor(process, Pid),
            true = nklib_proc:reg({?MODULE, Id}, Pid),
            nklib_proc:put(?MODULE, Id),
            EvOpts = case nkdocker_app:get(event_last_time, 0) of
                0 -> #{};
                Time -> #{since=>Time-1}
            end,
            case nkdocker:events(Pid, EvOpts) of
                {async, Ref} ->
                    Regs = nkdocker_app:get(monitor_callbacks, []),
                    case Regs of
                        [] -> ok;
                        _ -> ?LLOG(warning, "recovered callbacks: ~p", [Regs])
                    end,
                    Regs2 = nklib_util:store_value(CallBack, Regs),
                    ?LLOG(info, "server start (~p)", [Id]),
                    self() ! update_all,
                    {ok, #state{id=Id, server=Pid, event_ref=Ref, regs=Regs2}};
                {error, Error} ->
                    {stop, Error}
            end;
        {error, Error} ->
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({register, Module}, _From, #state{id=Id, regs=Regs}=State) ->
    Regs2 = nklib_util:store_value(Module, Regs),
    nkdocker_app:put(monitor_callbacks, Regs2),
    {reply, {ok, Id}, State#state{regs=Regs2}};

handle_call(get_containers, _From, #state{conts=Conts}=State) ->
    {reply, {ok, Conts}, State};

handle_call({get_container, Id}, _From, #state{conts=Conts}=State) ->
    Reply = case maps:find(Id, Conts) of
        {ok, Data} -> {ok, Data};
        error -> {error, not_found}
    end,
    {reply, Reply, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({unregister, Module}, #state{regs=Regs}=State) ->
    case Regs -- [Module] of
        [] ->
            {stop, normal, State};
        Regs2 ->
            nkdocker_app:put(monitor_callbacks, Regs2),
            {noreply, State#state{regs=Regs2}}
    end;

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({nkdocker, Ref, Data}, #state{event_ref=Ref}=State) ->
    {noreply, event(Data, State)};

handle_info({nkdocker, Ref, Data}, #state{stats_refs=Refs}=State) ->
    case maps:find(Ref, Refs) of
        {ok, Id} ->
            {noreply, stats(Id, Data, State)};
        error ->
            case Data of
                {ok, <<>>} ->
                    ok;
                _ ->
                    ?LLOG(notice, "stats received for unknown container: ~p", [Data])
            end,
            {noreply, State}
    end;

handle_info(update_all, State) ->
    State2 = update_all(State),
    erlang:send_after(?UPDATE_TIME, self(), update_all),
    {noreply, State2};

handle_info({'DOWN', _Ref, process, Pid, Reason}, #state{server=Pid}=State) ->
    ?LLOG(warning, "docker sever stopped: ~p", [Reason]),
    {stop, docker_server_stop, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->
    #state{server=Server, event_ref=Ref, stats_refs=Refs} = State,
    lists:foreach(
        fun(StatRef) -> nkdocker:finish_async(Server, StatRef) end, 
        maps:keys(Refs)),
    nkdocker:finish_async(Server, Ref), 
    case Reason of
        normal ->
            ?LLOG(info, "server stop normal", []),
            nkdocker_app:put(monitor_callbacks, []);
        _ ->
            ?LLOG(warning, "server stop anormal: ~p", [Reason]),
            ok
    end,
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================

%% @private
event({data, Event}, State) ->
    case Event of
        #{<<"status">>:=Status, <<"id">>:=Id, <<"time">>:=Time} ->
            From = maps:get(<<"from">>, Event, <<>>),
            Status2 = binary_to_atom(Status, latin1),
            notify({docker, {Id, Status2, From, Time}}, State),
            #state{time=Last} = State,
            State2 = case Time > Last of
                true ->
                    nkdocker_app:put(event_last_time, Time),
                    State#state{time=Time};
                false ->
                    State
            end,
            update(Status2, Id, State2);
        _ ->
            ?LLOG(warning, "unrecognized event: ~p", [Event]),
            State
    end;

event({error, Error}, _State) ->
    ?LLOG(warning, "events returned error: ~p", [Error]),
    error({events_error, Error});

event(Other, State) ->
    ?LLOG(warning, "unrecognized events: ~p", [Other]),
    State.


%% @private
stats(Id, {data, Data}, #state{conts=Conts}=State) ->
    case maps:find(Id, Conts) of
        {ok, Cont} ->
            Event = {stats, {Id, Data}},
            notify(Event, State),
            Cont2 = Cont#{stats=>Data},
            Conts2 = maps:put(Id, Cont2, Conts),
            State#state{conts=Conts2};
        error ->
            State2 = update(start, Id, State),
            stats(Id, {data, Data}, State2)
    end;

stats(Id, {error, Error}, _State) ->
    ?LLOG(warning, "stats returned error: ~p for: ~s", [Error, Id]),
    error({events_error, Error});

stats(Id, Other, State) ->
    ?LLOG(warning, "unrecognized stats: ~p for: ~s", [Other, Id]),
    State.



%% @private
notify(Data, #state{id=ServerId, regs=Regs}) ->
    lists:foreach(
        fun(Module) ->
            case catch Module:nkdocker_notify(ServerId, Data) of
                ok ->
                    ok;
                Error ->
                    ?LLOG(warning, "error calling ~p: ~p", [Module, Error])
            end
        end,
        Regs).


%% @private
-spec update(atom(), binary(), #state{}) ->
    #state{}.

update(start, Id, State) ->
    #state{server=Server, conts=Conts, stats_refs=Refs} = State,
    case maps:is_key(Id, Conts) of
        true ->
            State;
        false ->
            {ok, Data} = nkdocker:inspect(Server, Id),
            {async, Ref} = nkdocker:stats(Server, Id),
            #{<<"Name">>:=Name} = Data,
            #{<<"Config">>:=Config} = Data,
            #{<<"Labels">>:=Labels} = Config,
            Name2 = case Name of
                <<"/", SubName/binary>> -> SubName;
                _ -> Name
            end,
            ?LLOG(info, "monitoring container ~s (~s)", [Name2, Id]),
            notify({start, {Name2, Id, Labels}}, State),
            Cont = #{
                name => Name2,
                labels => Labels,
                data => Data, 
                stats => #{},
                stats_ref => Ref
            },
            Conts2 = maps:put(Id, Cont, Conts),
            Refs2 = maps:put(Ref, Id, Refs),
            State#state{conts=Conts2, stats_refs=Refs2}
    end;

update(die, Id, State) ->
    #state{conts=Conts, stats_refs=Refs} = State,
    case maps:find(Id, Conts) of
        {ok, #{stats_ref:=Ref, name:=Name, labels:=Labels}} ->
            ?LLOG(info, "stopping monitoring container ~s (~s)", [Name, Id]),
            notify({stop, {Name, Id, Labels}}, State),
            Conts2 = maps:remove(Id, Conts),
            Refs2 = maps:remove(Ref, Refs),
            State#state{conts=Conts2, stats_refs=Refs2};
        error ->
            State
    end;

update(_Status, _Id, State) ->
    State.


%% @private
update_all(#state{server=Server, conts=Conts}=State) ->
    {ok, List} = nkdocker:ps(Server),
    OldIds = maps:keys(Conts),
    NewIds = [Id || #{<<"Id">>:=Id} <- List],
    State2 = remove_old(OldIds--NewIds, State),
    start_new(NewIds--OldIds, State2).


%% @private
remove_old([], State) ->
    State;
remove_old([Id|Rest], State) ->
    ?LLOG(notice, "detected removal of container ~s", [Id]),
    remove_old(Rest, update(die, Id, State)).


%% @private
start_new([], State) ->
    State;
start_new([Id|Rest], State) ->
    ?LLOG(notice, "detected container ~s", [Id]),
    start_new(Rest, update(start, Id, State)).






