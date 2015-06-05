%% Module based on an old erl_tar.erl, but returning binaries and very simplified
%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1997-2013. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%


-module(nkdocker_tar).
-export([add/2]).

add(Name, Bin) ->
    Mtime0 = calendar:now_to_local_time(now()),
    Mtime = posix_time(erlang:localtime_to_universaltime(Mtime0)),
    {Prefix,Suffix} = split_filename(Name),
    H0 = [
		to_string(Suffix, 100),
		to_octal(8#100644, 8),
		to_octal(0, 8),
		to_octal(0, 8),
		to_octal(byte_size(Bin), 12),
		to_octal(Mtime, 12),
		<<"        ">>,
		$0,
		to_string([], 100),
		"ustar", 0,
		"00",
		zeroes(80),
		to_string(Prefix, 167)
	],
    H = list_to_binary(H0),
    512 = byte_size(H),		
    ChksumString = to_octal(checksum(H), 6, [0,$\s]),
    <<Before:148/binary, _:8/binary, After/binary>> = H,
    [Before, ChksumString, After, Bin, padding(byte_size(Bin), 512)].

    
to_octal(Int, Count) when Count > 1 ->
    to_octal(Int, Count-1, [0]).

to_octal(_, 0, Result) -> 
	Result;
to_octal(Int, Count, Result) ->
    to_octal(Int div 8, Count-1, [Int rem 8 + $0|Result]).


to_string(Str0, Count) ->
    Str = case file:native_name_encoding() of
		utf8 ->
			unicode:characters_to_binary(Str0);
		latin1 ->
			list_to_binary(Str0)
		end,
    case byte_size(Str) of
		Size when Size < Count ->
	    	[Str|zeroes(Count-Size)];
		_ -> 
			Str
    end.


split_filename(Name) when length(Name) =< 100 ->
    {"", Name};
split_filename(Name0) ->
    split_filename(lists:reverse(filename:split(Name0)), [], [], 0).

split_filename([Comp|Rest], Prefix, Suffix, Len) when Len+length(Comp) < 100 ->
    split_filename(Rest, Prefix, [Comp|Suffix], Len+length(Comp)+1);
split_filename([Comp|Rest], Prefix, Suffix, Len) ->
    split_filename(Rest, [Comp|Prefix], Suffix, Len+length(Comp)+1);
split_filename([], Prefix, Suffix, _) ->
    {filename:join(Prefix),filename:join(Suffix)}.


checksum(Bin) -> 
	checksum(Bin, 0).

checksum(<<A,B,C,D,E,F,G,H,T/binary>>, Sum) ->
    checksum(T, Sum+A+B+C+D+E+F+G+H);
checksum(<<A,T/binary>>, Sum) ->
    checksum(T, Sum+A);

checksum(<<>>, Sum) -> 
	Sum.


padding(Size, BlockSize) ->
    zeroes(pad_size(Size, BlockSize)).

pad_size(Size, BlockSize) ->
    case Size rem BlockSize of
		0 -> 0;
		Rem -> BlockSize-Rem
    end.


zeroes(0) -> 
	[];
zeroes(1) -> 
	[0];
zeroes(2) -> 
	[0,0];
zeroes(Number) ->
    Half = zeroes(Number div 2),
    case Number rem 2 of
		0 -> [Half|Half];
		1 -> [Half|[0|Half]]
    end.


posix_time(Time) ->
    EpochStart = {{1970,1,1},{0,0,0}},
    {Days,{Hour,Min,Sec}} = calendar:time_difference(EpochStart, Time),
    86400*Days + 3600*Hour + 60*Min + Sec.
