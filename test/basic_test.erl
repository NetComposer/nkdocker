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

-module(basic_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nkdocker.hrl").

-define(RECV(M), receive M -> ok after 1000 -> error(?LINE) end).

basic_test_() ->
  	{setup, spawn, 
    	fun() -> 
    		nkdocker_app:start(),
    		Opts = #{						% Read from environment vars or uncomment
    			% host = "127.0.0.1",
    			% port = 0,
    			% proto = tls,
    			% keyfile = ""
    			% certfile =""
    		},
    		{ok, C} = nkdocker:start_link(Opts),
    		?debugMsg("Starting BASIC test"),
    		C
		end,
		fun(C) -> 
			nkdocker:stop(C)
		end,
	    fun(C) ->
		    [
				fun() -> conns(C) end,
                {timeout, 60, fun() -> images(C) end},
                {timeout, 60, fun() -> run(C) end}
			]
		end
  	}.


conns(C) ->
    %% Stop all connections, if active
    [nkpacket_connection:stop(N, normal) || N <- nkpacket:get_all({nkdocker, C})],
    [nkpacket_connection:stop(N, normal) || N <- nkpacket:get_all({nkdocker, exclusive})],
    timer:sleep(100),

	{async, Ref} = nkdocker:events(C),
    timer:sleep(50),
    % We have only the events exclusive connection
    [] = [N || N <- nkpacket:get_all({nkdocker, C})],
    [#nkport{pid=ConnPid}] = nkpacket:get_all({nkdocker, exclusive}),
    ConnRef = erlang:monitor(process, ConnPid),
    % Conns = [N || N <- nkpacket:get_all({nkdocker, exclusive})],
    % [] = [N || N <-Conns, nkpacket:get_pid(N)/=ConnPid],

    {ok, #{<<"ApiVersion">>:=_}} = nkdocker:version(C),
    {ok, #{<<"Containers">>:=_}} = nkdocker:info(C),
    ok = nkdocker:ping(C),
    1 = length([N || N <- nkpacket:get_all({nkdocker, C})]),
    ok = nkdocker:finish_async(C, Ref),
    ?RECV({nkdocker, Ref, {ok, user_stop}}),
    ?RECV({'DOWN', ConnRef, process, ConnPid, normal}).


images(C) ->
    ?debugMsg("Building image from image1.tar (imports busybox:latest)"),
    Dir = filename:join(filename:dirname(code:priv_dir(nkdocker)), "test"),
    {ok, ImageTar1} = file:read_file(filename:join(Dir, "image1.tar")),
    {ok, List1} = nkdocker:build(C, ImageTar1, #{t=>"nkdocker:test1", force_rm=>true}),
    [#{<<"stream">>:=<<"Successfully built ", Id1:12/binary, "\n">>}|_] = 
        lists:reverse(List1),
    {ok, #{<<"Id">>:=FullId1}=Img1} = nkdocker:inspect_image(C, Id1),
    % lager:warning("Id: ~p, FullId1: ~p", [Id1, FullId1]),

    {ok, Img1} = nkdocker:inspect_image(C, "nkdocker:test1"),
    <<Id1:12/binary, _/binary>> = FullId1,
    {ok, [#{<<"Id">>:=FullId1}|_]} = nkdocker:history(C, Id1),
    case nkdocker:tag(C, Id1, #{repo=>"nkdocker", tag=>"test2"}) of
        ok -> ok;
        {error, {conflict, _}} -> ok
    end,
    {ok, #{<<"Id">>:=FullId1}} = nkdocker:inspect_image(C, "nkdocker:test2"),
    {ok, _} = nkdocker:rmi(C, <<"nkdocker:test1">>),
    {error, {not_found, _}} = nkdocker:inspect_image(C, "nkdocker:test1"),

    ?debugMsg("Building image from busybox:latest"),
    {ok, _} = nkdocker:create_image(C, #{fromImage=>"busybox:latest"}),
    {ok, #{<<"Id">>:=FullId1}} = nkdocker:inspect_image(C, "busybox:latest"),
    ok.


run(C) ->
    ?debugMsg("Starting run test"),
    nkdocker:kill(C, "nkdocker1"),
    nkdocker:rm(C, "nkdocker1"),

    {async, Ref} = nkdocker:events(C),

    ?debugMsg("Start container from busybox:latest"),
    {ok, #{<<"Id">>:=Id1}} = nkdocker:create(C, "busybox:latest", 
        #{
            name => "nkdocker1",
            interactive => true,
            tty => true,
            cmd => ["/bin/sh"]
        }),
    ?debugMsg("... created"),
    receive_status(Ref, Id1, <<"create">>),

    {ok, #{<<"Id">>:=Id1}=Data1} = nkdocker:inspect(C, Id1),
    {ok, Data1} = nkdocker:inspect(C, "nkdocker1"),

    ok = nkdocker:start(C, Id1),
    receive_status(Ref, Id1, <<"start">>),

    ok = nkdocker:pause(C, "nkdocker1"),
    receive_status(Ref, Id1, <<"pause">>),

    ok = nkdocker:unpause(C, "nkdocker1"),
    receive_status(Ref, Id1, <<"unpause">>),

    Self = self(),
    spawn(
        fun() -> 
            {ok, R} = nkdocker:wait(C, "nkdocker1", 5000),
            Self ! {wait, Ref, R}
        end),

    ok = nkdocker:kill(C, "nkdocker1"),
    receive_status(Ref, Id1, <<"die">>),
    receive_status(Ref, Id1, <<"kill">>),
    ?RECV({wait, Ref, #{<<"StatusCode">> := 137}}),

    ok = nkdocker:start(C, Id1),
    receive_status(Ref, Id1, <<"start">>),

    {async, Ref2} = nkdocker:attach(C, Id1),
    ok = nkdocker:attach_send(C, Ref2, "cat /etc/hostname\r\n"),
    Msg1 = receive_msg(Ref2, <<>>),
    <<ShortId1:12/binary, _/binary>> = Id1,
    <<"cat /etc/hostname\r\n", ShortId1:12/binary, _/binary>> = Msg1,

    {ok, [
        <<"/ # \n">>, 
        <<"/ # cat /etc/hostname\n">>, 
        <<ShortId1:12/binary, "\n">>,
        <<"/ # \n">>
    ]} = 
        nkdocker:logs(C, ShortId1, #{stdout=>true}),

    ok = nkdocker:rename(C, ShortId1, "nkdocker2"),
    ok = nkdocker:restart(C, "nkdocker2"),
    ?RECV({nkdocker, Ref2, {error, connection_failed}}),

    receive_status(Ref, Id1, <<"die">>),
    receive_status(Ref, Id1, <<"start">>),
    receive_status(Ref, Id1, <<"restart">>),

    ok = nkdocker:kill(C, "nkdocker2"),
    receive_status(Ref, Id1, <<"kill">>),
    receive_status(Ref, Id1, <<"die">>),
    ok = nkdocker:rm(C, "nkdocker2"),
    receive_status(Ref, Id1, <<"destroy">>),

    nkdocker:finish_async(C, Ref),
    ?RECV({nkdocker, Ref, {ok, user_stop}}),
    ok.



%% Internal

receive_status(Ref, Id, Status) ->
    ?RECV({nkdocker, Ref, {data, #{<<"id">>:=Id, <<"status">>:=Status}}}).

receive_msg(Ref, Buf) ->
    receive 
        {nkdocker, Ref, {data, Data}} ->
            receive_msg(Ref, <<Buf/binary, Data/binary>>)
    after 
        500 -> Buf
    end.

