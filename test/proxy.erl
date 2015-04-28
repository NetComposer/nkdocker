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

-module(proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/1]).
-export([transports/0, conn_init/1, conn_bridge/3]).

-include("nkdocker.hrl").

start(Opts) ->
    EnvConfig = application:get_env(nkdocker, conn_config, #{}),
    Opts1 = maps:merge(EnvConfig, Opts),
    Host = maps:get(host, Opts1, "127.0.0.1"),
    Port = maps:get(port, Opts1, 2375),
    Proto = maps:get(proto, Opts1, tcp),
    [Ip] = nkpacket_dns:get_ips(?MODULE, Host),
    Conn = {?MODULE, Proto, Ip, Port},
    ListenPort = maps:get(listen_port, Opts1, 12375),
    ListenConn = {?MODULE, tcp, {0,0,0,0}, ListenPort},
    ListenOpts = #{
        tcp_listeners => 1, 
        user => #{conn=>Conn, conn_opts => maps:with([certfile, keyfile], Opts1)}
    },
    nkpacket:start_listener(?MODULE, ListenConn, ListenOpts).



%%% Callbacks

-record(state, {
    type,
    conn_port
}).


transports() -> [tcp].


conn_init(Port) ->
    case nkpacket:get_user(Port) of
        {ok, #{conn:=Conn, conn_opts:=ConnOpts}} ->
            ConnOpts1 = ConnOpts#{force_new=>true, user=>secondary},
            lager:debug("PROXY Starting Connection to ~p, ~p", [Conn, ConnOpts]),
            case nkpacket:connect(?MODULE, Conn, ConnOpts1) of
                {ok, ConnPort} ->
                    {bridge, ConnPort, #state{type=up, conn_port=ConnPort}};
                _ ->
                    {stop, could_not_connect}
            end;
        {ok, secondary} ->
            {ok, #state{type=down, conn_port=Port}}
    end.


conn_bridge(Data, Type, State) ->
    lager:warning("Data (~p)", [Type]),
    print(Data),
    {ok, Data, State}.


print(Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Headers, <<${, _/binary>>=Json] ->
            case catch jiffy:decode(Json, []) of
                {'EXIT', _} ->
                    lager:notice("~s", [Data]);
                {Map} ->
                    lager:notice("~s\r\n\r\n~s", [Headers, jiffy:encode({lists:sort(Map)}, [pretty])])
                    % lager:notice("~s\r\n\r\n~s", [Headers, jiffy:encode(Map, [pretty])])
            end;
        _ ->
            lager:notice("~s", [Data])
    end.

