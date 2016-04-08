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

%% @doc Utility module.
-module(nkdocker_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_conn_info/0, get_conn_info/1]).
-export([remove_exited/0, build/2]).
-export([make_tar/1, docker_exec/1, docker_exec/2]).

%% ===================================================================
%% Public
%% ===================================================================



%% @private
-spec get_conn_info() ->
    {ok, nkdocker:conn_opts()|#{ip=>inet:ip_address()}} | {error, invalid_host}.

get_conn_info() ->
	get_conn_info(#{}).


%% @private
-spec get_conn_info(nkdocker:conn_opts()) ->
    {ok, nkdocker:conn_opts()|#{ip=>inet:ip_address()}} | {error, invalid_host}.

get_conn_info(Opts) ->
    {ok, EnvConfig} = application:get_env(nkdocker, conn_config),
    #{host:=Host} = Opts1 = maps:merge(EnvConfig, Opts),
    case nkpacket_dns:ips(Host) of
        [Ip|_] ->
            {ok, Opts1#{ip=>Ip}};
        _ ->
            {error, invalid_host}
    end.



%% @doc Removes all exited containers
-spec remove_exited() ->
	ok | {error, term()}.

remove_exited() ->
	Op = fun(Pid) ->
		case nkdocker:ps(Pid, #{filters=>#{status=>[exited]}}) of
			{ok, List} ->
				Ids = [Id || #{<<"Id">>:=Id} <- List],
				remove_exited(Pid, Ids);
			{error, Error} ->
				{error, Error}
		end
	end,
	docker_exec(Op).


%% @doc 
-spec build(string()|binary(), binary()) ->
	ok | {error, term()}.

build(Tag, TarBin) ->
	Op = fun(Pid) ->
		case nkdocker:inspect_image(Pid, Tag) of
	    	{ok, _} ->
	    		ok;
			{error, {not_found, _}} ->
				lager:notice("Building docker image ~s", [Tag]),
				Timeout = 3600 * 1000,
	    		case nkdocker:build(Pid, TarBin, #{t=>Tag, async=>true, timeout=>Timeout}) of
	    			{async, Ref} ->
	    				case wait_async(Pid, Ref, Timeout) of
	    					ok ->
	    						case nkdocker:inspect_image(Pid, Tag) of
	    							{ok, _} -> ok;
	    							_ -> {error, image_not_built}
	    						end;
	    					{error, Error} ->
	    						{error, Error}
	    				end;
	    			{error, Error} ->
	    				{error, {build_error, Error}}
	    		end;
	    	{error, Error} ->
	    		{error, {inspect_error, Error}}
	    end
	end,
	docker_exec(Op).


make_tar(List) ->
	list_to_binary([nkdocker_tar:add(Path, Bin) || {Path, Bin} <- List]).


%% @private
docker_exec(Fun) ->
	docker_exec(Fun, #{}).


%% @private
docker_exec(Fun, Opts) ->
	case nkdocker:start(Opts) of
		{ok, Pid} ->
			Res = (catch Fun(Pid)),
			nkdocker:stop(Pid),
			Res;
		{error, Error} ->
			{error, Error}
	end.




%% ===================================================================
%% Private
%% ===================================================================


%% @private
remove_exited(_Pid, []) ->
	ok;

remove_exited(Pid, [Id|Rest]) ->
	case nkdocker:rm(Pid, Id) of
		ok -> 
			lager:info("Removed ~s", [Id]);
		{error, Error} ->
			lager:notice("NOT Removed ~s: ~p", [Id, Error])
	end,
	remove_exited(Pid, Rest).


%% @private
wait_async(Pid, Ref, Timeout) ->
	Mon = monitor(process, Pid),
	Result = wait_async_iter(Ref, Mon, Timeout),
	demonitor(Mon),
	Result.


wait_async_iter(Ref, Mon, Timeout) ->
	receive
		{nkdocker, Ref, {data, #{<<"stream">> := Text}}} ->
			io:format("~s", [Text]),
			wait_async_iter(Ref, Mon, Timeout);
		{nkdocker, Ref, {data, #{<<"status">> := Text}}} ->
			io:format("~s", [Text]),
			wait_async_iter(Ref, Mon, Timeout);
		{nkdocker, Ref, {data, Data}} ->
			io:format("~p\n", [Data]),
			wait_async_iter(Ref, Mon, Timeout);
		{nkdocker, Ref, {ok, _}} ->
			ok;
		{nkdocker, Ref, {error, Reason}} ->
			{error, Reason};
		{nkdocker, Ref, Other} ->
			lager:warning("Unexpected msg: ~p", [Other]),
			wait_async_iter(Ref, Mon, Timeout);
		{'DOWN', Mon, process, _Pid, _Reason} ->
			{error, process_failed}
	after 
		Timeout ->
			{error, timeout}
	end.
