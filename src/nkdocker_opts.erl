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

%% @doc NkDOCKER Options
-module(nkdocker_opts).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile(export_all).

-export([make_path/2, create_spec/1]).
-export([parse_text/0]).
-import(nklib_util, [to_binary/1, to_host/1]).

-include("nkdocker.hrl").


%% ===================================================================
%% Path generator parser
%% ===================================================================

%% @private
-spec make_path(binary(), [{atom(), term()}]) ->
    binary().

make_path(Path, List) ->
    case iter_path(List, <<>>) of
        <<>> -> 
            Path;
        <<$&, Encoded/binary>> -> 
            <<Path/binary, $?, Encoded/binary>>
    end.
        

%% @private
iter_path([], Acc) ->
    Acc;

iter_path([{Key, Val}|Rest], Acc) when is_map(Val) ->
    iter_path([{Key, jiffy:encode(Val)}|Rest], Acc);

iter_path([{Key, Val}|Rest], Acc) ->
    iter_path(Rest, list_to_binary([Acc, $&, to_binary(Key), $=, to_urlencode(Val)])).



%% ===================================================================
%% Create spec parser
%% ===================================================================

%% @private
-spec create_spec(nkdocker:create_opts()) ->
    {ok, map()} | {error, term()}.

create_spec(Map) ->
    try
        create_spec(maps:to_list(Map), create_default())
    catch
        throw:TError -> {error, TError}
    end.


%% @private
create_spec([], Acc) ->
    {ok, Acc};

create_spec([{attach, List}|Rest], Acc) when is_list(List) ->
    {In, Out, Err} = case lists:sort(List) of
        [stdin] -> {true, false, false};
        [stdout] -> {false, true, true};
        [stderr] -> {false, true, true};
        [stdin, stdout] -> {true, true, false};
        [stderr, stdin] -> {true, false, true};
        [stderr, stdout] -> {false, true, true};
        [stderr, stdin, stdout] -> {true, true, true};
        _ -> throw({invalid_option, {attach, List}})
    end,
    Acc1 = Acc#{'AttachStdin'=>In, 'AttachStdout'=>Out, 'AttachStderr'=>Err},
    create_spec(Rest, Acc1);

create_spec([{add_hosts, List}|Rest], Acc) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {Host, Ip} -> list_to_binary([to_binary(Host), $:, to_host(Ip)]);
                _ -> throw({invalid_option, {add_hosts, List}})
            end
        end,
        List),
    create_spec_host(Rest, 'ExtraHosts', List1, Acc);

create_spec([{cidfile, Text}|Rest], Acc) ->
    create_spec_host(Rest, 'ContainerIDFile', to_binary(Text), Acc);

create_spec([{cpu_shares, Int}|Rest], Acc) when is_integer(Int) ->
    create_spec(Rest, Acc#{'CpuShares'=>Int});

create_spec([{cpu_set, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'Cpuset'=>to_binary(Text)});

create_spec([{cap_add, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'CapAdd', to_list(List), Acc);

create_spec([{cap_drop, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'CapDrop', to_list(List), Acc);

create_spec([{cmds, List}|Rest], Acc) when is_list(List) ->
    create_spec(Rest, Acc#{'Cmd'=>to_list(List)});

create_spec([{devices, List}|Rest], Acc) when is_list(List) ->
    Devices = lists:map(
        fun(Term) ->
            {PathHost, PathCont, Perm} = case Term of
                {A, B, C} -> {A, B, C};
                {A, B} -> {A, B, <<"rwm">>};
                A -> {A, A, <<"rwm">>}
            end,
            #{
                'PathOnHost' => to_binary(PathHost),
                'PathInContainer' => to_binary(PathCont),
                'CgroupPermissions' => to_binary(Perm)
            }
        end,
        List),
    create_spec_host(Rest, 'Devices', Devices,  Acc);

create_spec([{dns, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'Dns', to_list(List), Acc);

create_spec([{dns_search, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'DnsSearch', to_list(List), Acc);

create_spec([{env, List}|Rest], Acc) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {K, V} -> list_to_binary([to_binary(K), $=, to_binary(V)]);
                _ -> throw({invalid_option, {env, List}})
            end
        end,
        List),
    create_spec(Rest, Acc#{'Env'=>List1});

create_spec([{entrypoints, List}|Rest], Acc) when is_list(List) ->
    create_spec(Rest, Acc#{'Entrypoint'=>to_list(List)});

create_spec([{expose, List}|Rest], Acc) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {Port, tcp} when is_integer(Port)-> {to_port(Port, tcp), #{}};
                {Port, udp} when is_integer(Port)-> {to_port(Port, udp), #{}};
                Port when is_integer(Port) -> {to_port(Port, tcp), #{}};
                _ -> throw({invalid_option, {expose, List}})
            end
        end,
        List),
    create_spec(Rest, Acc#{'ExposedPorts'=>maps:from_list(List1)});

create_spec([{hostname, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'Hostname'=>to_binary(Text)});

create_spec([{interactive, true}|Rest], Acc) ->
    create_spec(Rest, Acc#{
        'AttachStdin' => true,
        'OpenStdin' => true,
        'StdinOnce' => true
    });

create_spec([{interactive, false}|Rest], Acc) ->
    create_spec(Rest, Acc);

create_spec([{image, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'Image'=>to_binary(Text)});

create_spec([{ipc, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'IpcMode'=>to_binary(Text)});

create_spec([{links, List}|Rest], Acc) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {Cont, Alias} -> list_to_binary([to_binary(Cont), $:, to_binary(Alias)]);
                _ -> throw({invalid_option, {links, List}})
            end
        end,
        List),
    create_spec_host(Rest, 'Links', List1, Acc);

create_spec([{lxc_confs, List}|Rest], Acc) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {K, V} -> #{'Key'=>to_binary(K), 'Val'=>to_binary(V)};
                _ -> throw({invalid_option, {lxc_confs, List}})
            end
        end,
        List),
    create_spec_host(Rest, 'LxcConf', List1, Acc);

create_spec([{mac_address, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'MacAddress'=>to_binary(Text)});

create_spec([{memory, Int}|Rest], Acc) when is_integer(Int) ->
    create_spec(Rest, Acc#{'Memory'=>Int});

create_spec([{memory_swap, Int}|Rest], Acc) when is_integer(Int) ->
    create_spec(Rest, Acc#{'MemorySwap'=>Int});

create_spec([{net, Text}|Rest], Acc) ->
    create_spec_host(Rest, 'NetworkMode', to_binary(Text), Acc);

create_spec([{publish_all, Bool}|Rest], Acc) when is_boolean(Bool) ->
    create_spec_host(Rest, 'PublishAllPorts', Bool, Acc);

create_spec([{publish, List}|Rest], Acc) when is_list(List) ->
    Expose = maps:get('ExposedPorts', Acc, #{}),
    {Expose1, Bind1} = lists:foldl(
        fun(Term, {ExpAcc, BindAcc}) ->
            {ContPort, HostPort, Ip} = case Term of
                {A, B, C} when is_integer(B) -> {A, to_binary(B), to_host(C)};
                {A, B} when is_integer(B) -> {A, to_binary(B), <<>>};
                A -> {A, <<>>, <<>>}
            end,
            Cont = case ContPort of
                {D, tcp} when is_integer(D) -> to_port(D, tcp);
                {D, udp} when is_integer(D) -> to_port(D, udp);
                D when is_integer(D) -> to_port(D, tcp);
                _ -> throw({invalid_option, {publish, List}})
            end,
            {
                maps:put(Cont, #{}, ExpAcc), 
                maps:put(Cont, #{'HostIp'=>Ip, 'HostPort'=>HostPort}, BindAcc)
            }
        end,
        {Expose, #{}},
        List),
    Acc1 = Acc#{'ExposedPorts'=>Expose1},
    create_spec_host(Rest, 'PortBindings',Bind1, Acc1);

create_spec([{pid, Text}|Rest], Acc) ->
    create_spec_host(Rest, 'PidMode', to_binary(Text), Acc);

create_spec([{privileged, Bool}|Rest], Acc) when is_boolean(Bool) ->
    create_spec_host(Rest, 'Privileged', Bool, Acc);

create_spec([{read_only, Bool}|Rest], Acc) when is_boolean(Bool) ->
    create_spec_host(Rest, 'ReadonlyRootfs', Bool, Acc);

create_spec([{restart, {on_failure, Retry}}|Rest], Acc) when is_integer(Retry) ->
    Restart = #{'Name'=><<"on-failure">>, 'MaximumRetryCount'=>Retry},
    create_spec_host(Rest, 'RestartPolicy', Restart, Acc);
    
create_spec([{restart, Name}|Rest], Acc) when Name==no; Name==always ->
    Restart = #{'Name'=>to_binary(Name), 'MaximumRetryCount'=>0},
    create_spec_host(Rest, 'RestartPolicy', Restart, Acc);

create_spec([{security_opts, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'SecurityOpt', to_list(List), Acc);

create_spec([{tty, Bool}|Rest], Acc) when is_boolean(Bool) ->
    create_spec(Rest, Acc#{'Tty'=>Bool});

create_spec([{user, String}|Rest], Acc) ->
    create_spec(Rest, Acc#{'User'=>to_binary(String)});

create_spec([{volumes, List}|Rest], Acc) when is_list(List) ->
    Volumes = maps:get('Volumes', Acc, #{}),
    {Volumes1, Binds1} = lists:foldl(
        fun(Term, {VolAcc, BindAcc}) ->
            case Term of
                {Host, Cont} ->
                    {VolAcc, [list_to_binary([Host, $:, Cont])|BindAcc]};
                Cont ->
                    {maps:put(to_binary(Cont), #{}, VolAcc), BindAcc}
            end
        end,
        {Volumes, []},
        List),
    Acc1 = Acc#{'Volumes'=>Volumes1},
    create_spec_host(Rest, 'Binds', Binds1, Acc1);

create_spec([{volumes_from, List}|Rest], Acc) when is_list(List) ->
    create_spec_host(Rest, 'VolumesFrom', to_list(List), Acc);

create_spec([{workdir, Text}|Rest], Acc) ->
    create_spec(Rest, Acc#{'WorkingDir'=>to_binary(Text)});

create_spec([{Key, _}=Term|_], _) 
            when Key==attach; Key==add_hosts; Key==cpu_shares; Key==cap_add;
                 Key==cap_drop; Key==cmds; Key==devices; Key==dns; Key==dns_search;
                 Key==env; Key==entrypoints; Key==expose; Key==interactive;
                 Key==lxc_confs; Key==memory; Key==memory_swap; Key==publish;
                 Key==privileged; Key==read_only; Key==restart; Key==security_opts;
                 Key==tty; Key==volumes; Key==volumes_from ->
    throw({invalid_option, Term});

create_spec([_|Rest], Acc) ->
    create_spec(Rest, Acc).



%% ===================================================================
%% Utilities
%% ===================================================================


%% @private
create_spec_host(Rest, Key, Value, #{'HostConfig':=HostConfig}=Acc) ->
    Acc1 = Acc#{'HostConfig':=maps:put(Key, Value, HostConfig)},
    create_spec(Rest, Acc1).


%% @private
to_list(Text) when is_list(Text) ->
    [to_binary(Term) || Term <- Text].


%% @private
to_urlencode(Text) ->
    to_binary(http_uri:encode(nklib_util:to_list(Text))).


%% @private
to_port(Port, Transp) ->
    <<(to_binary(Port))/binary, $/, (to_binary(Transp))/binary>>.


%% @private Default create using client v1.5
create_default() ->
    #{
        'AttachStdin' => false,
        'AttachStdout' => true,
        'AttachStderr' => true,
        'Cmd' => null,
        'CpuShares' => 0,
        'Cpuset' => <<>>,
        'Domainname' => <<>>,
        'Entrypoint' => null,
        'Env' => [],
        'ExposedPorts' => #{},
        'Hostname' => <<>>,
        % 'Image' => 'ubuntu',
        'MacAddress' => <<>>,
        'Memory' => 0,
        'MemorySwap' => 0,
        'NetworkDisabled' => false,
        'OnBuild' => null,
        'OpenStdin' => false,
        'PortSpecs' => null,
        'StdinOnce' => false,
        'Tty' => false,
        'User' => <<>>,
        'Volumes' => #{},
        'WorkingDir' => <<>>,
        'HostConfig' => #{
            'Binds' => null,
            'CapAdd' => null,
            'CapDrop' => null,
            'ContainerIDFile' => <<>>,
            'Devices' => [],
            'Dns' => null,
            'DnsSearch' => null,
            'ExtraHosts' => null,
            'IpcMode' => <<>>,
            'Links' => null,
            'LxcConf' => [],
            'NetworkMode' => 'bridge',
            'PidMode' => <<>>,
            'PortBindings' => #{},
            'Privileged' => false,
            'PublishAllPorts' => false,
            'ReadonlyRootfs' => false,
            'RestartPolicy' => #{'MaximumRetryCount' => 0,'Name' => <<>>},
            'SecurityOpt' => null,
            'VolumesFrom' => null
        }
    }.





%% ===================================================================
%% Test
%% ===================================================================


parse_text() ->
    Spec = #{
        attach => [stdin, stdout],
        add_hosts => [{"host1", {1,2,3,4}}, {"host2", <<"5.6.7.8">>}],
        cap_add => ["cap1", "cap2"],
        cap_drop => ["drop1", "drop2"],
        cidfile => "mycidfile",
        cmds => ["cmd1"],
        cpu_set => <<"0,1">>,
        cpu_shares => 500,
        devices => ["p1", {<<"p2">>, "p3"}, {"p4", "p5", "p6"}],
        dns => ["dns1", "dns2"],
        dns_search => ["dns3", <<"dns4">>],
        env => [{"env1", "val1"}, {"env2", "val2"}],
        entrypoints => ["a", "b"],
        expose => [1000, {1001, tcp}, {1002, udp}],
        hostname => "hostname1",
        interactive => true,
        image => <<"image1">>,
        links => [{"link1", "value1"}],
        lxc_confs => [{"lx1", "lv1"}],
        mac_address => "1:2:3:4:5:6:7:8",
        memory => 1000,
        memory_swap => -1,
        net => none,
        publish_all => true,
        publish => [2000, {2001, udp}, {2002, 2102}, {{2003, udp}, 2103, {1,2,3,4}}], 
        privileged => true,
        read_only => true,
        restart => {on_failure, 5},
        security_opts => ["s1", "s2"],
        tty => true,
        user => "user",
        volumes => ["vol1", {<<"vol2">>, <<"vol3">>}],
        volumes_from => ["from1"],
        workdir => "work"
    },
    {ok, Op} = create_spec(maps:to_list(Spec), create_default()),
    #{
        'AttachStdin' := true,
        'AttachStdout' := true,
        'AttachStderr' := false,
        'Cmd' := [<<"cmd1">>],
        'Cpuset' := <<"0,1">>,
        'CpuShares' := 500,
        'Env' := [<<"env1=val1">>,<<"env2=val2">>],
        'Entrypoint' := [<<"a">>,<<"b">>],
        'ExposedPorts' := #{
            <<"1000/tcp">> := #{},
            <<"1001/tcp">> := #{},
            <<"1002/udp">> := #{},
            <<"2000/tcp">> := #{},
            <<"2001/udp">> := #{},
            <<"2002/tcp">> := #{},
            <<"2003/udp">> := #{}
        },
        'Hostname' := <<"hostname1">>,
        'Image' := <<"image1">>,
        'MacAddress' := <<"1:2:3:4:5:6:7:8">>,
        'Memory' := 1000,
        'MemorySwap' := -1,
        'NetworkDisabled' := false,
        'OpenStdin' := true,
        'StdinOnce' := true,
        'Tty' := true,
        'User' := <<"user">>,
        'Volumes' := #{<<"vol1">> := #{}},
        'WorkingDir' := <<"work">>,
        'HostConfig' := #{
            'Binds' := [<<"vol2:vol3">>],
            'CapAdd' := [<<"cap1">>,<<"cap2">>],
            'CapDrop' := [<<"drop1">>,<<"drop2">>],
            'ContainerIDFile' := <<"mycidfile">>,
            'Devices' := [
                #{
                    'CgroupPermissions' := <<"rwm">>,
                    'PathInContainer' := <<"p1">>,
                    'PathOnHost' := <<"p1">>
                },
                #{
                    'CgroupPermissions' := <<"rwm">>,
                    'PathInContainer' := <<"p3">>,
                    'PathOnHost' := <<"p2">>
                },
                #{
                    'CgroupPermissions' := <<"p6">>,
                    'PathInContainer' := <<"p5">>,
                    'PathOnHost' := <<"p4">>
                }
            ],
            'Dns' := [<<"dns1">>,<<"dns2">>],
            'DnsSearch' := [<<"dns3">>,<<"dns4">>],
            'ExtraHosts' := [<<"host1:1.2.3.4">>,<<"host2:5.6.7.8">>],
            'Links' := [<<"link1:value1">>],
            'LxcConf' := [#{'Key' := <<"lx1">>,'Val' := <<"lv1">>}],
            'NetworkMode' := <<"none">>,
            'PortBindings' := #{
                <<"2000/tcp">> := #{'HostIp' := <<>>,'HostPort' := <<>>},
                <<"2001/udp">> := #{'HostIp' := <<>>,'HostPort' := <<>>},
                <<"2002/tcp">> := #{'HostIp' := <<>>,'HostPort' := <<"2102">>},
                <<"2003/udp">> := #{'HostIp' := <<"1.2.3.4">>,'HostPort' := <<"2103">>}
            },
            'Privileged' := true,
            'PublishAllPorts' := true,
            'ReadonlyRootfs' := true,
            'RestartPolicy' := #{'MaximumRetryCount' := 5,'Name' := <<"on-failure">>},
            'SecurityOpt' := [<<"s1">>,<<"s2">>],
            'VolumesFrom' := [<<"from1">>]
        }
    } = Op,
    ok.
    
