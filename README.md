# NkDOCKER: Scalable Erlang Docker client

NkDOCKER is a native, 100% Erlang [Docker](https://www.docker.com) client, using the [Docker Remote API](https://docs.docker.com/reference/api/docker_remote_api_v1.17/) v1.17.

* **Full v1.17 (Docker 1.5) API supported**. Every command and option of the standard Docker client is available.
* Can control any number of local or remote Docker daemons.
* Events, stdin/stdout/stderr attachs, logs, etc., are sent as Erlang messages.
* Can reuse existing connections to speed up the message sending.
* It supports TCP and TLS transports. Unix socket transport is not supported yet.

NkDOCKER needs Erlang >= 17.

While more documentation is available, look at [this file](test/basic_test.erl) for a complete example of use


