# NkDOCKER: Erlang Docker Client

NkDOCKER is a native, 100% Erlang [Docker](https://www.docker.com) client, fully supporting the [Docker Remote API](https://docs.docker.com/reference/api/docker_remote_api_v1.18/) v1.18. Every single command and option in the standard Docker client is available.

* **Full v1.18 (Docker 1.6) API supported**. 
* It supports bidirectional attach.
* It can control any number of local or remote Docker daemons.
* Events, stdin/stdout/stderr attachs, logs, etc., are sent as Erlang messages.
* It can reuse existing connections to speed up the message sending.
* It supports TCP and TLS transports. Unix socket transport is not supported yet.

NkDOCKER needs Erlang >= 17, and it is tested on Linux and OSX (using boot2docker). The minimum required Docker server version is _1.5_ (Remote API v1.17). It is part of the Nekso software suite, but can be used stand-alone.

## Starting a connection

Before sending any operation, you must connect to the Docker daemon, calling [`nkdocker:start/1`](src/nkdocker.erl) or `nkdocker:start_link/1`. NkDOCKER will start a new standard `gen_server`, returning its `pid()`. You must specify the connection options:

```erlang
-type text() :: string() | binary().

-type conn_opts() ::
	#{	
		host => text(),					% Default "127.0.0.1"
		port => inet:port_number(),		% Default 2375
		proto => tcp | tls,				% Default tcp
		certfile => text(),
		keyfile => text()
	}.
```

You can now start sending commands to the Docker daemon. Some commands (usually quick, non-blocking commands) will try to reuse the same command, while other commands will start a fresh connection and will close it when finished (See the documentation of each command at [nkdocker.erl](src/nkdocker.erl)).

These parameters (host, port, proto, certfile and keyfile) can also be included as standard Erlang application environment variable for `nkdocker`. You can also indicate the connection parameters using standard OS environment variables. The follow keys are recognized:

Key|Value
---|---
DOCKER_HOST|Host to connect to, i.e "tcp://127.0.0.1:2375"
DOCKER_TLS|If "1" or "true" TLS will be used
DOCKER_TLS_VERIFY|If "1" or "true" TLS will be usedta
DOCKER_CERT_PATH|Path to the directory containing 'cert.pem' and 'key.pem'


## Sending commands

After connection to the daemon, you can start sending commands, for example (the OS variables DOCKER_HOST, DOCKER_TLS and DOCKER_CERT must be setted for this to work):

```erlang
> {ok, P} = nkdocker:start_link().
{ok, <...>}

> nkdocker:version(P).
{ok,#{<<"ApiVersion">> => <<"1.18">>,
      <<"Arch">> => <<"amd64">>,
      <<"GitCommit">> => <<"4749651">>,
      <<"GoVersion">> => <<"go1.4.2">>,
      <<"KernelVersion">> => <<"3.18.11-tinycore64">>,
      <<"Os">> => <<"linux">>,
      <<"Version">> => <<"1.6.0">>}}
```

Let's create a new container:

```erlang
nkdocker:create(P, "busybox:latest",
    #{
        name => "nkdocker1",
        interactive => true,
        tty => true,
        cmds => ["/bin/sh"]
    }).
{ok, #{<<"Id">> => ...}}
```

## Async comamnds

NkPACKET allows several async commands, for example to get Docker events:

```erlang
> nkdocker:events(P).
{ok, #Ref<0.0.3.103165>}
```

Now every selected event (all for this example) will be sent to the process:

```erlang
> nkdocker:start(P, "nkdocker1").
ok

> flush().
Shell got {nkdocker,#Ref<0.0.3.103165>,
                    #{<<"from">> => <<"busybox:latest">>,
                      <<"id">> => ...,
                      <<"status">> => <<"start">>, ... }}

```

See [nkdocker.erl](nkdocker.erl) to find all available commands.


## Docker Monitor

Its is possible to start a long-running docker client calling nkdocker_monitor:register/1,2.
The server will be started with the first registration, and removed after the last one is unregistered.

All events from docker will be sent to the callback module, as well as stats and other specific information.




