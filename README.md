# NkDOCKER: Scalable Erlang Docker client

NkDOCKER is a native, 100% Erlang [Docker](https://www.docker.com) client, using the [Docker Remote API](https://docs.docker.com/reference/api/docker_remote_api_v1.17/) v1.17.

* **Full v1.17 (Docker 1.5) API supported**. Every single command and option in the standard Docker client is available.
* It supports bidirectional attach.
* It can control any number of local or remote Docker daemons.
* Events, stdin/stdout/stderr attachs, logs, etc., are sent as Erlang messages.
* It can reuse existing connections to speed up the message sending.
* It supports TCP and TLS transports. Unix socket transport is not supported yet.

NkDOCKER needs Erlang >= 17.

While more documentation is available, look at [nkdocker.erl](src/nkdocker.erl) and [the tests](test/basic_test.erl) for a complete example of use. For it to work, define the DOCKER_HOST, DOCKER_CERT_PATH and DOCKER_TLS environment variables.


