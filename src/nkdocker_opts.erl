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
%% software distri ted under the License is distributed on an
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

-export([make_path/2, create_spec/2]).
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
    iter_path([{Key, nklib_json:encode(Val)}|Rest], Acc);

iter_path([{Key, Val}|Rest], Acc) ->
    iter_path(Rest, list_to_binary([Acc, $&, to_binary(Key), $=, to_urlencode(Val)])).



%% ===================================================================
%% Create spec parser
%% ===================================================================

%% @private
all_opts() ->
    [
        attach, add_hosts, 
        cap_add, cap_drop, cgroup_parent, cidfile, cmds, cpu_set, 
        cpu_set_cpus, cpu_shares, 
        devices, dns, dns_search, domain_name,
        env, entrypoints, expose,
        hostname,
        interactive,
        labels, links, lxc_confs, log_config, 
        mac_address, memory, memory_swap, 
        net,
        publish_all, publish, privilege,
        read_only, restart, 
        security_opts,
        tty,
        ulimits, user,
        volumes, volumes_from,
        workdir
    ].

%% @private
-spec create_spec(binary(), nkdocker:create_opts()) ->
    {ok, map()} | {error, term()}.

create_spec(Vsn, Map) ->
    try
        create_spec(Vsn, maps:to_list(Map), create_default_a(Vsn), create_default_b(Vsn))
    catch
        throw:TError -> {error, TError}
    end.


%% @private
create_spec(_, [], AccA, AccB) ->
    {ok, AccA#{'HostConfig' => AccB}};

create_spec(Vsn, [{attach, List}|Rest], AccA, AccB) when is_list(List) ->
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
    AccA1 = AccA#{'AttachStdin'=>In, 'AttachStdout'=>Out, 'AttachStderr'=>Err},
    create_spec(Vsn, Rest, AccA1, AccB);

create_spec(Vsn, [{add_hosts, List}|Rest], AccA, AccB) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {Host, Ip} -> list_to_binary([to_binary(Host), $:, to_host(Ip)]);
                _ -> throw({invalid_option, {add_hosts, List}})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA, AccB#{'ExtraHosts'=>List1});

create_spec(Vsn, [{cgroup_parent, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA, AccB#{'CgroupParent'=>to_binary(Text)});

create_spec(Vsn, [{cidfile, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA, AccB#{'ContainerIDFile'=>to_binary(Text)});

create_spec(Vsn, [{cpu_shares, Int}|Rest], AccA, AccB) when is_integer(Int) ->
    AccA1 = AccA#{'CpuShares'=>Int},
    AccB1 = case Vsn >= <<"1.18">> of
        true -> AccB#{'CpuShares'=>Int};
        false -> AccB
    end,
    create_spec(Vsn, Rest, AccA1, AccB1);

create_spec(Vsn, [{cpu_set, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'Cpuset'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{cpu_set_cpus, Text}|Rest], AccA, AccB) ->
    AccA1 = AccA#{'Cpuset'=>to_binary(Text)},
    AccB1 = AccB#{'CpusetCpus'=>to_binary(Text)},
    create_spec(Vsn, Rest, AccA1, AccB1);

create_spec(Vsn, [{cap_add, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA, AccB#{'CapAdd'=>to_list(List)});

create_spec(Vsn, [{cap_drop, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA, AccB#{'CapDrop'=>to_list(List)});

create_spec(Vsn, [{cmds, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA#{'Cmd'=>to_list(List)}, AccB);

create_spec(Vsn, [{devices, List}|Rest], AccA, AccB) when is_list(List) ->
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
    create_spec(Vsn, Rest, AccA, AccB#{'Devices'=>Devices});

create_spec(Vsn, [{dns, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA, AccB#{'Dns'=>to_list(List)});

create_spec(Vsn, [{dns_search, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA, AccB#{'DnsSearch'=>to_list(List)});

create_spec(Vsn, [{domain_name, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'Domainname'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{env, List}|Rest], AccA, AccB) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {K, V} -> list_to_binary([to_binary(K), $=, to_binary(V)]);
                _ -> throw({invalid_option, {env, List}})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA#{'Env'=>List1}, AccB);

create_spec(Vsn, [{entrypoints, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA#{'Entrypoint'=>to_list(List)}, AccB);

create_spec(Vsn, [{expose, List}|Rest], AccA, AccB) when is_list(List) ->
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
    create_spec(Vsn, Rest, AccA#{'ExposedPorts'=>maps:from_list(List1)}, AccB);

create_spec(Vsn, [{hostname, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'Hostname'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{interactive, true}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{
        'AttachStdin' => true,
        'OpenStdin' => true,
        'StdinOnce' => true
    }, AccB);

create_spec(Vsn, [{interactive, false}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA, AccB);

create_spec(Vsn, [{image, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'Image'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{ipc, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'IpcMode'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{labels, List}|Rest], AccA, AccB) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {K, V} -> {to_binary(K), to_binary(V)};
                _ -> throw({invalid_option, {labels, List}})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA#{'Labels'=>maps:from_list(List1)}, AccB);

create_spec(Vsn, [{links, List}|Rest], AccA, AccB) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {Cont, Alias} -> list_to_binary([to_binary(Cont), $:, to_binary(Alias)]);
                _ -> throw({invalid_option, {links, List}})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA, AccB#{'Links'=>List1});

create_spec(Vsn, [{lxc_confs, List}|Rest], AccA, AccB) when is_list(List) ->
    List1 = lists:map(
        fun(Term) ->
            case Term of
                {K, V} -> #{'Key'=>to_binary(K), 'Val'=>to_binary(V)};
                _ -> throw({invalid_option, {lxc_confs, List}})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA, AccB#{'LxcConf'=>List1});

create_spec(Vsn, [{log_config, {Type, Config}}|Rest], AccA, AccB) when is_map(Config) ->
    Config = #{'Type'=>to_binary(Type), 'Config'=>Config},
    create_spec(Vsn, Rest, AccA, AccB#{'LogConfig'=>Config});

create_spec(Vsn, [{log_config, Type}|Rest], AccA, AccB) ->
    Config = #{'Type'=>to_binary(Type), 'Config'=>null},
    create_spec(Vsn, Rest, AccA, AccB#{'LogConfig'=>Config});

create_spec(Vsn, [{mac_address, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'MacAddress'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{memory, Int}|Rest], AccA, AccB) when is_integer(Int) ->
    AccA1 = AccA#{'Memory'=>Int},
    AccB1 = case Vsn >= <<"1.18">> of
        true -> AccB#{'Memory'=>Int};
        false -> AccB
    end,
    create_spec(Vsn, Rest, AccA1, AccB1);

create_spec(Vsn, [{memory_swap, Int}|Rest], AccA, AccB) when is_integer(Int) ->
    AccA1 = AccA#{'MemorySwap'=>Int},
    AccB1 = case Vsn >= <<"1.18">> of
        true -> AccB#{'MemorySwap'=>Int};
        false -> AccB
    end,
    create_spec(Vsn, Rest, AccA1, AccB1);

create_spec(Vsn, [{net, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA, AccB#{'NetworkMode'=>to_binary(Text)});

create_spec(Vsn, [{publish_all, Bool}|Rest], AccA, AccB) when is_boolean(Bool) ->
    create_spec(Vsn, Rest, AccA, AccB#{'PublishAllPorts'=>Bool});

create_spec(Vsn, [{publish, List}|Rest], AccA, AccB) when is_list(List) ->
    Expose = maps:get('ExposedPorts', AccA, #{}),
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
                maps:put(Cont, 
			 lists:usort(
			   [ #{'HostIp'=>Ip, 'HostPort'=>HostPort} | 
			   maps:get(Cont, BindAcc, [])]), 
			 BindAcc)
            }
        end,
        {Expose, #{}},
        List),
    create_spec(Vsn, Rest, AccA#{'ExposedPorts'=>Expose1}, AccB#{'PortBindings'=>Bind1});

% create_spec(Vsn, [{pid, Text}|Rest], AccA, AccB) ->
%     create_spec(Vsn, Rest, AccA, AccB#{'PidMode'=>to_binary(Text)});

create_spec(Vsn, [{privileged, Bool}|Rest], AccA, AccB) when is_boolean(Bool) ->
    create_spec(Vsn, Rest, AccA, AccB#{'Privileged'=>Bool});

create_spec(Vsn, [{read_only, Bool}|Rest], AccA, AccB) when is_boolean(Bool) ->
    create_spec(Vsn, Rest, AccA, AccB#{'ReadonlyRootfs'=>Bool});

create_spec(Vsn, [{restart, {on_failure, Retry}}|Rest], AccA, AccB) when is_integer(Retry) ->
    Restart = #{'Name'=><<"on-failure">>, 'MaximumRetryCount'=>Retry},
    create_spec(Vsn, Rest, AccA, AccB#{'RestartPolicy'=>Restart});
    
create_spec(Vsn, [{restart, Name}|Rest], AccA, AccB) when Name==no; Name==always ->
    Restart = #{'Name'=>to_binary(Name), 'MaximumRetryCount'=>0},
    create_spec(Vsn, Rest, AccA, AccB#{'RestartPolicy'=>Restart});

create_spec(Vsn, [{security_opts, List}|Rest], AccA, AccB) when is_list(List) ->
    create_spec(Vsn, Rest, AccA, AccB#{'SecurityOpt'=>to_list(List)});

create_spec(Vsn, [{tty, Bool}|Rest], AccA, AccB) when is_boolean(Bool) ->
    create_spec(Vsn, Rest, AccA#{'Tty'=>Bool}, AccB);

create_spec(Vsn, [{ulimits, List}|Rest], AccA, AccB) when is_list(List) ->
    Limits = lists:map(
        fun(Term) ->
            case Term of
                {Name, Soft, Hard} when is_integer(Soft), is_integer(Hard) -> 
                    #{'Name'=>to_binary(Name), 'Soft'=>Soft, 'Hard'=>Hard};
                _ ->
                    throw({invalid_option, ulimits})
            end
        end,
        List),
    create_spec(Vsn, Rest, AccA, AccB#{'Ulimits'=>Limits});

create_spec(Vsn, [{user, String}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'User'=>to_binary(String)}, AccB);

create_spec(Vsn, [{volumes, List}|Rest], AccA, AccB) when is_list(List) ->
    Volumes = maps:get('Volumes', AccA, #{}),
    {Volumes1, Binds1} = lists:foldl(
        fun(Term, {VolAcc, BindAcc}) ->
            case Term of
                {Host, Cont, ro} ->
                    {VolAcc, [list_to_binary([Host, $:, Cont, ":ro"])|BindAcc]};
                {Host, Cont} ->
                    {VolAcc, [list_to_binary([Host, $:, Cont])|BindAcc]};
                Cont ->
                    {maps:put(to_binary(Cont), #{}, VolAcc), BindAcc}
            end
        end,
        {Volumes, []},
        List),
    create_spec(Vsn, Rest, AccA#{'Volumes'=>Volumes1}, AccB#{'Binds'=>Binds1});

create_spec(Vsn, [{volumes_from, List}|Rest], AccA, AccB) when is_list(List) ->
    Volumes = lists:foldl(
        fun(Term, Acc) ->
            case Term of
                {Cont, ro} -> [list_to_binary([Cont, ":ro"])|Acc];
                {Cont, rw} -> [list_to_binary([Cont, ":rw"])|Acc];
                Cont -> [to_binary(Cont)|Acc]
            end
        end,
        [],
        List),
    create_spec(Vsn, Rest, AccA, AccB#{'VolumesFrom'=>Volumes});

create_spec(Vsn, [{workdir, Text}|Rest], AccA, AccB) ->
    create_spec(Vsn, Rest, AccA#{'WorkingDir'=>to_binary(Text)}, AccB);

create_spec(Vsn, [{Key, _}=Term|Rest], AccA, AccB) ->
    case lists:member(Key, all_opts()) of
        true -> throw({invalid_option, Term});
        false -> create_spec(Vsn, Rest, AccA, AccB)
    end.



%% ===================================================================
%% Utilities
%% ===================================================================


%% @private
to_list(Text) when is_list(Text) ->
    [to_binary(Term) || Term <- Text].


%% @private
to_urlencode(Text) ->
    to_binary(http_uri:encode(nklib_util:to_list(Text))).


%% @private
to_port(Port, Transp) ->
    <<(to_binary(Port))/binary, $/, (to_binary(Transp))/binary>>.


%% @private
create_default(Vsn) ->
    (create_default_a(Vsn))#{'HostConfig'=>create_default_b(Vsn)}.


%% @private Default create using client v1.5
create_default_a(<<"1.17">>) ->
    #{
        'AttachStderr' => true,
        'AttachStdin' => false,
        'AttachStdout' => true,
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
        'WorkingDir' => <<>>
    };

% >= 1.18
create_default_a(_) ->
    (create_default_a(<<"1.17">>))#{
        'Labels' => #{}
    }.




create_default_b(<<"1.17">>) ->
    #{
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
        'PidMode' => <<>>,              % not documented?
        'PortBindings' => #{},
        'Privileged' => false,
        'PublishAllPorts' => false,
        'ReadonlyRootfs' => false,
        'RestartPolicy' => #{'MaximumRetryCount' => 0,'Name' => <<>>},
        'SecurityOpt' => null,
        'VolumesFrom' => null
    };

create_default_b(_) ->
    (create_default_b(<<"1.17">>))#{
        'CgroupParent' => <<>>,     
        'CpusetCpus' => <<>>,
        'CpuShares' => 0,
        'LogConfig' => #{'Config' => null,'Type' => <<>>},
        'Memory' => 0,
        'MemorySwap' => 0,
        'RestartPolicy' => #{'MaximumRetryCount' => 0,'Name' => <<"no">>},
        'Ulimits' => null
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
        cgroup_parent => "path",
        cidfile => "mycidfile",
        cmds => ["cmd1"],
        cpu_set => <<"0,1">>,
        cpu_set_cpus => <<"2,3">>,
        cpu_shares => 500,
        devices => ["p1", {<<"p2">>, "p3"}, {"p4", "p5", "p6"}],
        dns => ["dns1", "dns2"],
        dns_search => ["dns3", <<"dns4">>],
        domain_name => "domain",
        env => [{"env1", "val1"}, {"env2", "val2"}],
        entrypoints => ["a", "b"],
        expose => [1000, {1001, tcp}, {1002, udp}],
        hostname => "hostname1",
        interactive => true,
        image => <<"image1">>,
        labels => [{"lk", lv}],
        links => [{"link1", "value1"}],
        lxc_confs => [{"lx1", "lv1"}],
        log_config => "none",
        mac_address => "1:2:3:4:5:6:7:8",
        memory => 1000,
        memory_swap => -1,
        net => none,
        publish_all => true,
        publish => [2000, {2001, udp}, {2002, 2102}, {{2003, udp}, 2103, {1,2,3,4}}], 
        % pid_mode => <<"what_is_this?">>,
        privileged => true,
        read_only => true,
        restart => {on_failure, 5},
        security_opts => ["s1", "s2"],
        tty => true,
        ulimits => [{"name", 1, 2}],
        user => "user",
        volumes => ["vol1", {<<"vol2">>, <<"vol3">>}, {"vol4", "vol5", ro}],
        volumes_from => ["from1", {"from2", ro}],
        workdir => "work"
    },
    {ok, Op} = create_spec(<<"1.18">>, Spec),
    #{
        'AttachStdin' := true,
        'AttachStdout' := true,
        'AttachStderr' := false,
        'Cmd' := [<<"cmd1">>],
        % 'Cpuset' := <<"0,1">>,          % Ignored in v1.18, next one overwrites it!
        'Cpuset' := <<"2,3">>, 
        'CpuShares' := 500,
        'Domainname' := <<"domain">>,
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
        'Labels' := #{ <<"lk">> := <<"lv">>},
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
            'Binds' := [<<"vol4:vol5:ro">>, <<"vol2:vol3">>],
            'CapAdd' := [<<"cap1">>,<<"cap2">>],
            'CapDrop' := [<<"drop1">>,<<"drop2">>],
            'CpusetCpus' := <<"2,3">>,
            'CpuShares' := 500,
            'CgroupParent' := <<"path">>,
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
            'LogConfig' := #{'Type' := <<"none">>, 'Config' := null},
            'Memory' := 1000,
            'MemorySwap' := -1,
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
            'Ulimits' := [#{'Hard' := 2,'Name' := <<"name">>,'Soft' := 1}],
            'VolumesFrom' := [<<"from2:ro">>, <<"from1">>]
        }
    } = Op.
    
    
