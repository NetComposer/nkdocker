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

%% @doc NkDOCKER OTP Application Module
-module(nkdocker_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([get_env/2]).

-include("nkdocker.hrl").
-include_lib("nklib/include/nklib.hrl").


-define(APP, nkdocker).

%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts NkDOCKER stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, permanent) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.

%% @private OTP standard start callback
start(_Type, _Args) ->
    _ = code:ensure_loaded(nkdocker_protocol),
    {ok, Pid} = nkdocker_sup:start_link(),
    {ok, Vsn} = application:get_key(nkdocker, vsn),
    lager:notice("NkDOCKER v~s has started.", [Vsn]),
    ConnOpts = get_config(),
    lager:notice("Default config: ~p", [ConnOpts]),
    application:set_env(?APP, conn_config, ConnOpts),
    {ok, Pid}.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% @private
get_config() ->
    case os:getenv("DOCKER_HOST") of
        false ->
            case get_env(proto, tcp) of
                tcp -> 
                    #{
                        host => get_env(host, "127.0.0.1"),
                        port => get_env(port, 2375),
                        proto => tcp
                    };
                tls ->
                    #{
                        host => get_env(host, "127.0.0.1"),
                        port => get_env(port, 2376),
                        proto => tls
                    }
            end;
        _ ->
            get_env_config()
    end.


get_env_config() ->
    case nklib_parse:uris(os:getenv("DOCKER_HOST")) of
        [#uri{scheme=tcp, domain=Domain, port=Port}] -> 
            ok;
        _  -> 
            Domain = Port = error("Unrecognized DOCKER_HOST env")
    end,
    case 
        os:getenv("DOCKER_TLS") == "1" orelse
        os:getenv("DOCKER_TLS") == "true" orelse
        os:getenv("DOCKER_TLS_VERIFY") == "1" orelse
        os:getenv("DOCKER_TLS_VERIFY") == "true"
    of
        true ->
            case os:getenv("DOCKER_CERT_PATH") of
                false ->
                    #{
                        host => Domain,
                        port => Port,
                        proto => tls
                    };
                Path ->
                    #{
                        host => Domain,
                        port => Port,
                        proto => tls, 
                        tls_certfile => filename:join(Path, "cert.pem"),
                        tls_keyfile => filename:join(Path, "key.pem")
                    }
            end;
        false ->
            #{
                host => Domain,
                port => Port,
                proto => tcp
            }
    end.


%% @private
get_env(Key, Default) ->
    application:get_env(?APP, Key, Default).


