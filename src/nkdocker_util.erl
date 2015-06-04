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

%% @doc Utility module.
-module(nkdocker_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([remove_exited/1]).


%% ===================================================================
%% Types
%% ===================================================================

%% @doc Removes all exited containers
-spec remove_exited(pid()) ->
	ok | {error, term()}.

remove_exited(Pid) ->
	case nkdocker:ps(Pid, #{filters=>#{status=>[exited]}}) of
		{ok, List} ->
			Ids = [Id || #{<<"Id">>:=Id} <- List],
			remove_exited(Pid, Ids);
		{error, Error} ->
			{error, Error}
	end.

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
