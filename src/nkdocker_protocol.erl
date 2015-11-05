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

%% @doc Protocol behaviour
-module(nkdocker_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([transports/1]).
-export([conn_init/1, conn_parse/3, conn_encode/3]).

-include_lib("nklib/include/nklib.hrl").

-record(state, {
	notify :: pid(),
	buff = <<>> :: binary(),
	streams = [] :: [reference()], 
	next = head :: head | {body, non_neg_integer()} | chunked | stream
}).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [tls].


%% @private
-spec conn_init(nkpacket:nkport()) ->
	{ok, #state{}}.

conn_init(NkPort) ->
	{ok, _SrvId, {notify, Pid}} = nkpacket:get_user(NkPort),
	% lager:notice("Protocol CONN init: ~p (~p)", [NkPort, self()]),
	{ok, #state{notify=Pid}}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
	{ok, #state{}} | {stop, normal, #state{}}.

conn_parse(close, _NkPort, State) ->
	{ok, State};

conn_parse(Data, _NkPort, State) ->
	handle(Data, State).


%% @private
-spec conn_encode(term(), nkpacket:nkport(), #state{}) ->
	{ok, nkpacket:raw_msg(), #state{}} | {error, term(), #state{}} |
	{stop, Reason::term()}.

conn_encode({http, Ref, Method, Path, Headers, Body}, _NkPort, State) ->
	request(Ref, Method, Path, Headers, Body, State);
	
conn_encode({data, Ref, Data}, _NkPort, State) ->
	data(Ref, Data, State).


%% ===================================================================
%% HTTP handle
%% ===================================================================

%% @private
-spec request(term(), binary(), binary(), list(), iolist(), #state{}) ->
	{ok, iolist(), #state{}}.

request(Ref, Method, Path, Headers, Body, #state{streams=Streams}=State) ->
	Headers1 = case is_map(Body) of
		true -> [{<<"content-type">>, <<"application/json">>}|Headers];
		false -> Headers
	end,
	Body1 = case is_map(Body) of
		true -> nklib_json:encode(Body);
		false -> Body
	end,
	Headers2 = [
		{<<"content-length">>, integer_to_list(iolist_size(Body1))}
		| Headers1
	],
	State1 = State#state{streams = Streams ++ [Ref]},
	RawMsg = cow_http:request(Method, Path, 'HTTP/1.1', Headers2),
	{ok, [RawMsg, Body1], State1}.


%% @private
-spec data(term(), iolist(), #state{}) ->
	{ok, iolist(), #state{}} | {error, invalid_ref, #state{}}.

data(_Ref, _Data, #state{streams=[]}=State) ->
	{error, invalid_ref, State};

data(Ref, Data, #state{streams=Streams}=State) ->
	case lists:last(Streams) of
		Ref -> 
			{ok, Data, State};
		_ ->
			{error, invalid_ref, State}
	end.


-spec handle(binary(), #state{}) ->
	{ok, #state{}} | {stop, term(), #state{}}.

handle(<<>>, State) ->
	{ok, State};

handle(_, #state{streams=[]}=State) ->
	{stop, normal, State};

handle(Data, #state{next=head, buff=Buff}=State) ->
	Data1 = << Buff/binary, Data/binary >>,
	case binary:match(Data1, <<"\r\n\r\n">>) of
		nomatch -> 
			{ok, State#state{buff=Data1}};
		{_, _} -> 
			handle_head(Data1, State#state{buff = <<>>})
	end;

handle(Data, #state{next={body, Length}}=State) ->
	#state{buff=Buff, streams=[Ref|_], notify=Pid} = State,
	Data1 = << Buff/binary, Data/binary>>,
	case byte_size(Data1) of
		Length ->
			Pid ! {nkdocker, Ref, {body, Data1}},
			{ok, do_next(State)};
		Size when Size < Length ->
			{ok, State#state{buff=Data1}};
		_ ->
			{Data2, Rest} = erlang:split_binary(Data1, Length),
			Pid ! {nkdocker, Ref, {body, Data2}},
			handle(Rest, do_next(State))
	end;

handle(Data, #state{next=chunked}=State) ->
	#state{buff=Buff, streams=[Ref|_], notify=Pid} = State,
	Data1 = << Buff/binary, Data/binary>>,
	case parse_chunked(Data1) of
		{data, <<>>, Rest} ->
			Pid ! {nkdocker, Ref, {body, <<>>}},
			handle(Rest, do_next(State));
		{data, Chunk, Rest} ->
			Pid ! {nkdocker, Ref, {chunk, Chunk}},
			handle(Rest, State#state{buff = <<>>});
		more ->
			{ok, State#state{buff=Data1}}
	end;

handle(Data, #state{next=stream, streams=[Ref|_], notify=Pid}=State) ->
	Pid ! {nkdocker, Ref, {chunk, Data}},
	{ok, State}.


%% @private
-spec handle_head(binary(), #state{}) ->
	{ok, #state{}}.

handle_head(Data, #state{streams=[Ref|_], notify=Pid}=State) ->
	{_Version, Status, _, Rest} = cow_http:parse_status_line(Data),
	{Headers, Rest2} = cow_http:parse_headers(Rest),
	Pid ! {nkdocker, Ref, {head, Status, Headers}},
	Remaining = case lists:keyfind(<<"content-length">>, 1, Headers) of
		{_, <<"0">>} -> 
			0;
		{_, Length} -> 
			cow_http_hd:parse_content_length(Length);
		false when Status==204; Status==304 ->
			0;
		false ->
			case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
				false ->
					stream;
				{_, TE} ->
					case cow_http_hd:parse_transfer_encoding(TE) of
						[<<"chunked">>] -> chunked;
						[<<"identity">>] -> 0
					end
			end
	end,
	State1 = case Remaining of
		0 -> 
			Pid ! {nkdocker, Ref, {body, <<>>}},
			do_next(State);
		chunked -> 
			State#state{next=chunked};
		stream -> 
			State#state{next=stream};
		_ -> 
			State#state{next={body, Remaining}}
	end,
	handle(Rest2, State1).



%% @private
-spec parse_chunked(binary()) ->
	{ok, binary(), binary()} | more.

parse_chunked(S) ->
    case find_chunked_length(S, []) of
        {ok, Length, Data} ->
            FullLength = Length + 2,
            case byte_size(Data) of
                FullLength -> 
                    <<Data1:Length/binary, "\r\n">> = Data,
                    {data, Data1, <<>>};
                Size when Size < FullLength ->
                    more;
                _ ->
                    {Data1, Rest} = erlang:split_binary(Data, FullLength),
                    <<Data2:Length/binary, "\r\n">> = Data1,
                    {data, Data2, Rest}
            end;
        more ->
            more
    end.


%% @private
-spec find_chunked_length(binary(), string()) ->
	{ok, integer(), binary()} | more.

find_chunked_length(<<C, "\r\n", Rest/binary>>, Acc) ->
    {V, _} = lists:foldl(
        fun(Ch, {Sum, Mult}) ->
            if 
                Ch >= $0, Ch =< $9 -> {Sum + (Ch-$0)*Mult, 16*Mult};
                Ch >= $a, Ch =< $f -> {Sum + (Ch-$a+10)*Mult, 16*Mult};
                Ch >= $A, Ch =< $F -> {Sum + (Ch-$A+10)*Mult, 16*Mult}
            end
        end,
        {0, 1},
        [C|Acc]),
    {ok, V, Rest};

find_chunked_length(<<C, Rest/binary>>, Acc) ->
    find_chunked_length(Rest, [C|Acc]);

find_chunked_length(<<>>, _Acc) ->
	more.


%% @private
do_next(#state{streams=[_|Rest]}=State) ->
	State#state{next=head, buff= <<>>, streams=Rest}.







