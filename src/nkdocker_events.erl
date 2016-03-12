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

-module(nkdocker_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([register/2, unregister/2, start_link/2, find/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).
-export_type([id/0, event/0]).

-define(LLOG(Type, Txt, Args), lager:Type("NkDOCKER Events "++Txt, Args)).

-callback nkdocker_event(id(), event()) ->
    ok.

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: {inet:ip_address(), inet:port()}.

-type event() :: {Status::atom(), Id::binary(), From::binary(), Time::integer()}.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Registers a server to listen to docker events
%% For each new event, Callback:nkdocker_event(event()) will be called
%% The first caller for a specific ip and port daemon will start the server
-spec register(nkdocker:conn_opts(), module()) ->
    {ok, pid()} | {error, term()}.

register(Opts, Callback) ->
    case find(Opts) of
        {ok, Id, not_found} ->
            case nkdocker_sup:start_events(Id, Opts) of
                {ok, Pid} ->
                    gen_server:call(Pid, {register, Callback});
                {error, Error} ->
                    {error, Error}
            end;
        {ok, _Id, Pid} ->
            gen_server:call(Pid, {register, Callback});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Unregisters a callback
%% After the last callback is unregistered, the server stops
unregister(Opts, Callback) ->
    case find(Opts) of
        {ok, _Id, not_found} ->
            ok;
        {ok, _Id, Pid} ->
            gen_server:cast(Pid, {unregister, Callback});
        {error, Error} ->
            {error, Error}
    end.



%% @private
start_link(Id, Opts) ->
    gen_server:start_link(?MODULE, [Id, Opts], []).


%% @private
find(Opts) ->
    case nkdocker_server:get_conn(Opts) of
        {ok, {Ip, #{port:=Port}}} ->
            Id = {Ip, Port},
            case nklib_proc:values({?MODULE, Id}) of
                [] ->
                    {ok, Id, not_found};
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
    ref :: reference(),
    regs = [] :: [module()]
}).


%% @private
-spec init(term()) ->
    {ok, tuple()} | {ok, tuple(), timeout()|hibernate} |
    {stop, term()} | ignore.

init([Id, Opts]) ->
    true = nklib_proc:reg({?MODULE, Id}),
    case nkdocker_server:start_link(Opts) of
        {ok, Pid} ->
            case nkdocker:events(Pid) of
                {async, Ref} ->
                    Regs = nkdocker_app:get(events_callbacks, []),
                    case Regs of
                        [] -> ok;
                        _ -> ?LLOG(warning, "recovered callbacks: ~p", [Regs])
                    end,
                    {ok, #state{id=Id, server=Pid, ref=Ref, regs=Regs}};
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

handle_call({register, Module}, _From, #state{regs=Regs}=State) ->
    Regs2 = nklib_util:store_value(Module, Regs),
    nkdocker_app:put(events_callbacks, Regs2),
    {reply, {ok, self()}, State#state{regs=Regs2}};

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
            nkdocker_app:put(events_callbacks, Regs2),
            {noreply, State#state{regs=Regs2}}
    end;

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({nkdocker, Ref, {data, Map}}, #state{ref=Ref}=State) ->
    {noreply, event(Map, State)};

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

terminate(Reason, _State) ->
    case Reason of
        normal ->
            ?LLOG(notice, "server stop normal", []),
            nkdocker_app:put(events_callbacks, []);
        _ ->
            ?LLOG(notice, "server stop anormal: ~p", [Reason]),
            ok
    end,
    ok.
    


% ===================================================================
%% Internal
%% ===================================================================


event(#{<<"status">>:=Status, <<"id">>:=Id, <<"time">>:=Time}=Msg, State) ->
    From = maps:get(<<"from">>, Msg, <<>>),
    Event = {binary_to_atom(Status, latin1), Id, From, Time},
    #state{id=ServerId, regs=Regs} = State,
    lists:foreach(
        fun(Module) ->
            case catch Module:nkdocker_event(ServerId, Event) of
                ok ->
                    ok;
                Error ->
                    ?LLOG(warning, "error calling ~p: ~p", [Module, Error])
            end
        end,
        Regs),
    State;

event(Event, State) ->
    lager:notice("Unrecognized event: ~p", [Event]),
    State.





