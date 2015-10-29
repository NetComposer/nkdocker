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
    		{ok, Pid} = nkdocker:start_link(Opts),
    		?debugMsg("Starting BASIC test"),
    		Pid
		end,
		fun(Pid) -> 
			nkdocker:stop(Pid)
		end,
	    fun(Pid) ->
		    [
				fun() -> conns(Pid) end,
                {timeout, 60, fun() -> images(Pid) end},
                {timeout, 60, fun() -> run(Pid) end}
			]
		end
  	}.


conns(Pid) ->
    nkpacket_connection:stop_all({nkdocker, Pid}),
    nkpacket_connection:stop_all({nkdocker, Pid, exclusive}),
    timer:sleep(100),
    [] = nkpacket_connection:get_all({nkdocker, Pid}),
    [] = nkpacket_connection:get_all({nkdocker, Pid, exclusive}),
   
	{async, Ref} = nkdocker:events(Pid),
    timer:sleep(50),

    % We have only the events exclusive connection
    [] = nkpacket_connection:get_all({nkdocker, Pid}),
    [ConnPid1] = nkpacket_connection:get_all({nkdocker, Pid, exclusive}),
    ConnRef = erlang:monitor(process, ConnPid1),

    {ok, #{<<"ApiVersion">>:=_}} = nkdocker:version(Pid),
    {ok, #{<<"Containers">>:=_}} = nkdocker:info(Pid),
    ok = nkdocker:ping(Pid),
    % Now we have the previous and a 'shared' connection
    [ConnPid2] = nkpacket_connection:get_all({nkdocker, Pid}),
    [ConnPid1] = nkpacket_connection:get_all({nkdocker, Pid, exclusive}),
    ok = nkdocker:finish_async(Pid, Ref),
    ?RECV({nkdocker, Ref, {ok, user_stop}}),
    ?RECV({'DOWN', ConnRef, process, ConnPid1, normal}),
    [ConnPid2] = nkpacket_connection:get_all({nkdocker, Pid}),
    [] = nkpacket_connection:get_all({nkdocker, Pid, exclusive}),
    true = ConnPid1 /= ConnPid2,
    ok.


images(Pid) ->
    ?debugMsg("Building image from image1.tar (imports busybox:latest)"),
    Dir = filename:join(filename:dirname(code:priv_dir(nkdocker)), "test"),
    {ok, ImageTar1} = file:read_file(filename:join(Dir, "image1.tar")),
    {ok, List1} = nkdocker:build(Pid, ImageTar1, #{t=>"nkdocker:test1", force_rm=>true}),
    [#{<<"stream">>:=<<"Successfully built ", Id1:12/binary, "\n">>}|_] = 
        lists:reverse(List1),
    {ok, #{<<"Id">>:=FullId1}=Img1} = nkdocker:inspect_image(Pid, Id1),
    <<Id1:12/binary, _/binary>> = FullId1,
    % lager:warning("Id: ~p, FullId1: ~p", [Id1, FullId1]),

    {ok, Img1} = nkdocker:inspect_image(Pid, "nkdocker:test1"),
    {ok, [#{<<"Id">>:=FullId1}|_]} = nkdocker:history(Pid, Id1),
    case nkdocker:tag(Pid, Id1, #{repo=>"nkdocker", tag=>"test2", force=>true}) of
        ok -> ok;
        {error, {conflict, _}} -> ok
    end,
    {ok, #{<<"Id">>:=FullId1}} = nkdocker:inspect_image(Pid, "nkdocker:test2"),
    {ok, _} = nkdocker:rmi(Pid, <<"nkdocker:test1">>),
    {error, {not_found, _}} = nkdocker:inspect_image(Pid, "nkdocker:test1"),

    ?debugMsg("Building image from busybox:latest"),
    {ok, _} = nkdocker:create_image(Pid, #{fromImage=>"busybox:latest"}),
    {ok, #{<<"Id">>:=FullId1}} = nkdocker:inspect_image(Pid, "busybox:latest"),
    ok.


run(Pid) ->
    ?debugMsg("Starting run test"),
    nkdocker:kill(Pid, "nkdocker1"),
    nkdocker:rm(Pid, "nkdocker1"),

    {async, Ref} = nkdocker:events(Pid),

    ?debugMsg("Start container from busybox:latest"),
    {ok, #{<<"Id">>:=Id1}} = nkdocker:create(Pid, "busybox:latest", 
        #{
            name => "nkdocker1",
            interactive => true,
            tty => true,
            cmd => ["/bin/sh"]
        }),
    ?debugMsg("... created"),
    receive_status(Ref, Id1, <<"create">>),

    {ok, #{<<"Id">>:=Id1}=Data1} = nkdocker:inspect(Pid, Id1),
    {ok, Data1} = nkdocker:inspect(Pid, "nkdocker1"),

    ok = nkdocker:start(Pid, Id1),
    receive_status(Ref, Id1, <<"start">>),

    ok = nkdocker:pause(Pid, "nkdocker1"),
    receive_status(Ref, Id1, <<"pause">>),

    ok = nkdocker:unpause(Pid, "nkdocker1"),
    receive_status(Ref, Id1, <<"unpause">>),

    Self = self(),
    spawn(
        fun() -> 
            {ok, R} = nkdocker:wait(Pid, "nkdocker1", 5000),
            Self ! {wait, Ref, R}
        end),

    ok = nkdocker:kill(Pid, "nkdocker1"),
    receive_status(Ref, Id1, <<"die">>),
    receive_status(Ref, Id1, <<"kill">>),
    ?RECV({wait, Ref, #{<<"StatusCode">> := 137}}),

    ok = nkdocker:start(Pid, Id1),
    receive_status(Ref, Id1, <<"start">>),

    {async, Ref2} = nkdocker:attach(Pid, Id1),
    ok = nkdocker:attach_send(Pid, Ref2, "cat /etc/hostname\r\n"),
    Msg1 = receive_msg(Ref2, <<>>),
    <<ShortId1:12/binary, _/binary>> = Id1,
    <<"cat /etc/hostname\r\n", ShortId1:12/binary, _/binary>> = Msg1,

    {ok, TList} = nkdocker:logs(Pid, ShortId1, #{stdout=>true}),
    {match, _} = re:run(TList, "cat /etc/hostname"),
    {match, _} = re:run(TList, ShortId1),

    ok = nkdocker:rename(Pid, ShortId1, "nkdocker2"),
    ok = nkdocker:restart(Pid, "nkdocker2"),
    ?RECV({nkdocker, Ref2, {error, connection_failed}}),

    receive_status(Ref, Id1, <<"die">>),
    receive_status(Ref, Id1, <<"start">>),
    receive_status(Ref, Id1, <<"restart">>),

    ok = nkdocker:kill(Pid, "nkdocker2"),
    receive_status(Ref, Id1, <<"kill">>),
    receive_status(Ref, Id1, <<"die">>),
    ok = nkdocker:rm(Pid, "nkdocker2"),
    receive_status(Ref, Id1, <<"destroy">>),

    nkdocker:finish_async(Pid, Ref),
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

