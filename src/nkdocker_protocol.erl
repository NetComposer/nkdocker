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
-export([conn_init/1, conn_parse/2, conn_unparse/2]).

-include_lib("nklib/include/nklib.hrl").

-record(state, {
	nkport :: nkpacket:nkport(),
	notify :: pid(),
	buffer = <<>> :: binary(),
	streams = [] :: [reference()], 
	in = head :: head | {body, non_neg_integer()} | chunked | stream,
	in_state :: {non_neg_integer(), non_neg_integer()}
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
	#state{}.

conn_init(NkPort) ->
	{ok, {notify, Pid}} = nkpacket:get_user(NkPort),
	% lager:notice("Protocol CONN init: ~p (~p)", [NkPort, self()]),
	#state{nkport=NkPort, notify=Pid}.


%% @private
-spec conn_parse(term()|close, #state{}) ->
	{ok, #state{}} | {stop, normal, #state{}}.

conn_parse(close, State) ->
	{ok, State};

conn_parse(Data, #state{notify=Notify}=State) ->
	case handle(Data, State) of
		{ok, State1} ->
			{ok, State1};
		{reply, Reply, <<>>, State1} ->
			Notify ! {nkdocker, Reply},
			{ok, State1};
		{reply, Reply, Rest, State1} ->
			Notify ! {nkdocker, Reply},
			conn_parse(Rest, State1);
		{stop, normal, State1} ->
			{stop, normal, State1}
	end.


%% @private
-spec conn_unparse(term(), #state{}) ->
	{ok, nkpacket:raw_msg(), #state{}} | {error, term(), #state{}} |
	{stop, Reason::term()}.

conn_unparse({http, Ref, Method, Path, Headers, Body}, State) ->
	request(Ref, Method, Path, Headers, Body, State);
	
conn_unparse({data, Ref, Data}, State) ->
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
		true -> jiffy:encode(Body, [pretty]);
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
	{ok, #state{}} | {reply, Reply, Rest::binary(), #state{}} |	{stop, normal, #state{}}
	when Reply :: 
		{head, Ref::term(), Status::pos_integer(), Headers::list(), Last::boolean()}
		| {data, iolist(), Last::boolean()}.

handle(<<>>, State) ->
	{ok, State};

handle(_, #state{streams=[]}=State) ->
	{stop, normal, State};

handle(Data, #state{in=head, buffer=Buffer}=State) ->
	Data2 = << Buffer/binary, Data/binary >>,
	case binary:match(Data, <<"\r\n\r\n">>) of
		nomatch -> 
			{ok, State#state{buffer=Data2}};
		{_, _} -> 
			handle_head(Data2, State#state{buffer= <<>>, in_state={0,0}})
	end;

handle(Data, #state{in={body, Remaining}, streams=[Ref|RestStreams]}=State) ->
	case byte_size(Data) of
		Remaining ->
			State1 = State#state{in=head, streams=RestStreams},
			{reply, {data, Ref, Data, true}, <<>>, State1};
		Length when Length < Remaining ->
			Remaining1 = Remaining - Length,
			State1 = State#state{in={body, Remaining1}},
			{reply, {data, Ref, Data, false}, <<>>, State1};
		Length ->
			<< Body:Length/binary, Rest/bits >> = Data,
			State1 = State#state{in=head, streams=RestStreams},
			{reply, {data, Ref, Body, true}, Rest, State1}
	end;

handle(Data, #state{in=chunked}=State) ->
	#state{in_state=InState, streams=[Ref|RestStreams], buffer=Buffer} = State,
	Buffer2 = << Buffer/binary, Data/binary >>,
	case cow_http_te:stream_chunked(Buffer2, InState) of
		more ->
			State#state{buffer=Buffer2};
		{more, Data2, InState2} ->
			State1 = State#state{buffer= <<>>, in_state=InState2},
			{reply, {data, Ref, Data2, false}, <<>>, State1};
		{more, Data2, Length, InState2} when is_integer(Length) ->
			State1 = State#state{buffer= <<>>, in_state=InState2},
			{reply, {data, Ref, Data2, false}, <<>>, State1};
		{more, Data2, Rest, InState2} ->
			State1 = State#state{buffer=Rest, in_state=InState2},
			{reply, {data, Ref, Data2, false}, <<>>, State1};
		{done, _TotalLength, Rest} ->
			State1 = State#state{in=head, buffer= <<>>, streams=RestStreams},
			{reply, {data, Ref, <<>>, true}, Rest, State1};
		{done, Data2, _TotalLength, Rest} ->
			State1 = State#state{in=head, buffer= <<>>, streams=RestStreams},
			{reply, {data, Ref, Data2, true}, Rest, State1}
	end;

handle(Data, #state{in=stream, streams=[Ref|_]}=State) ->
	{reply, {data, Ref, Data, false}, <<>>, State}.


%% @private
-spec handle_head(binary(), #state{}) ->
	{reply, Reply, Rest::binary(), #state{}}
	when Reply :: 
		{head, Ref::term(), Status::pos_integer(), Headers::list(), Last::boolean()}.

handle_head(Data, State) ->
	#state{streams=[Ref|RestStreams]} = State,
	{_Version, Status, _, Rest} = cow_http:parse_status_line(Data),
	{Headers, Rest2} = cow_http:parse_headers(Rest),
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
		0 -> State#state{in=head, streams=RestStreams};
		chunked -> State#state{in=chunked};
		stream -> State#state{in=stream};
		_ -> State#state{in={body, Remaining}}
	end,
	{reply, {head, Ref, Status, Headers, Remaining==0}, Rest2, State1}.

