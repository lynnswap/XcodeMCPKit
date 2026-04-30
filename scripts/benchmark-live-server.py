#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import os
import sys
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any


DEFAULT_ENDPOINT = "http://localhost:8765/mcp"
ENDPOINT_ENV = "XCODE_MCP_PROXY_ENDPOINT"
DISCOVERY_FILE_ENV = "XCODE_MCP_PROXY_DISCOVERY_FILE"
CACHE_ROOT_ENV = "XCODE_MCP_PROXY_CACHE_ROOT"
SESSION_HEADER = "Mcp-Session-Id"
PROTOCOL_VERSION = "2025-03-26"


class BenchmarkError(RuntimeError):
    pass


class SessionBoundError(BenchmarkError):
    def __init__(self, message: str, session_id: str | None) -> None:
        super().__init__(message)
        self.session_id = session_id


@dataclass(frozen=True)
class Endpoint:
    url: str
    host: str
    port: int
    target: str
    host_header: str


@dataclass(frozen=True)
class HTTPRawResponse:
    status: int
    headers: dict[str, str]
    body: bytes


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    headers: dict[str, str]
    body: dict[str, Any]


@dataclass(frozen=True)
class AgentResult:
    agent_index: int
    connect_seconds: float
    initialize_seconds: float
    request_started_at: float
    request_finished_at: float
    request_seconds: float
    total_seconds: float
    request_latencies: list[float]


class Progress:
    def __init__(self, total: int, interval: int) -> None:
        self.total = total
        self.interval = interval
        self.completed = 0

    def record(self) -> None:
        self.completed += 1
        if self.interval and self.completed % self.interval == 0:
            print(f"completed {self.completed}/{self.total}")


class StartBarrier:
    def __init__(self, parties: int) -> None:
        self.parties = parties
        self.arrived = 0
        self.aborted = False
        self.event = asyncio.Event()
        self.lock = asyncio.Lock()

    async def wait(self) -> None:
        async with self.lock:
            if self.aborted:
                raise BenchmarkError("benchmark start was aborted")
            self.arrived += 1
            if self.arrived == self.parties:
                self.event.set()
        await self.event.wait()
        if self.aborted:
            raise BenchmarkError("benchmark start was aborted")

    async def abort(self) -> None:
        async with self.lock:
            self.aborted = True
            self.event.set()


class HTTPConnection:
    def __init__(
        self,
        endpoint: Endpoint,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        timeout: float,
    ) -> None:
        self.endpoint = endpoint
        self.reader = reader
        self.writer = writer
        self.timeout = timeout

    @classmethod
    async def open(cls, endpoint: Endpoint, timeout: float) -> HTTPConnection:
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(endpoint.host, endpoint.port),
                timeout=timeout,
            )
        except asyncio.TimeoutError as error:
            raise BenchmarkError(f"connect timed out after {timeout:g}s") from error
        except OSError as error:
            raise BenchmarkError(f"connect failed: {error}") from error
        return cls(endpoint, reader, writer, timeout)

    def write_json(
        self,
        payload: dict[str, Any],
        session_id: str | None,
        close: bool = False,
    ) -> None:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        headers = [
            f"POST {self.endpoint.target} HTTP/1.1",
            f"Host: {self.endpoint.host_header}",
            "Content-Type: application/json",
            "Accept: application/json",
            f"Connection: {'close' if close else 'keep-alive'}",
            f"Content-Length: {len(body)}",
        ]
        if session_id is not None:
            headers.append(f"{SESSION_HEADER}: {session_id}")
        request = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body
        self.writer.write(request)

    def write_delete(self, session_id: str, close: bool = True) -> None:
        headers = [
            f"DELETE {self.endpoint.target} HTTP/1.1",
            f"Host: {self.endpoint.host_header}",
            f"Connection: {'close' if close else 'keep-alive'}",
            f"{SESSION_HEADER}: {session_id}",
            "Content-Length: 0",
        ]
        request = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii")
        self.writer.write(request)

    async def flush(self) -> None:
        try:
            await asyncio.wait_for(self.writer.drain(), timeout=self.timeout)
        except asyncio.TimeoutError as error:
            raise BenchmarkError(f"write timed out after {self.timeout:g}s") from error
        except OSError as error:
            raise BenchmarkError(f"write failed: {error}") from error

    async def read_raw_response(self) -> HTTPRawResponse:
        try:
            status_line = await asyncio.wait_for(self.reader.readline(), timeout=self.timeout)
            if not status_line:
                raise BenchmarkError("server closed the connection before sending a response")
            status = parse_status(status_line)
            headers = await read_headers(self.reader, self.timeout)
            body = await read_body(self.reader, headers, self.timeout)
        except asyncio.TimeoutError as error:
            raise BenchmarkError(f"response timed out after {self.timeout:g}s") from error
        except asyncio.IncompleteReadError as error:
            raise BenchmarkError(f"server closed the response body early: {error}") from error
        except OSError as error:
            raise BenchmarkError(f"response read failed: {error}") from error

        return HTTPRawResponse(status=status, headers=headers, body=body)

    async def read_response(self) -> HTTPResponse:
        raw_response = await self.read_raw_response()
        status = raw_response.status
        headers = raw_response.headers
        body = raw_response.body
        response_json = decode_json(body)
        if not 200 <= status <= 299:
            raise BenchmarkError(f"HTTP {status}: {compact(response_json)}")
        return HTTPResponse(status=status, headers=headers, body=response_json)

    async def close(self) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except OSError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark an already-running xcode-mcp-proxy-server. Each agent "
            "opens one MCP session, sends DocumentationSearch requests in a "
            "closed loop, then reports throughput and per-request latency "
            "percentiles."
        )
    )
    parser.add_argument(
        "--endpoint",
        help=(
            "Proxy endpoint URL. Defaults to XCODE_MCP_PROXY_ENDPOINT, then the "
            "discovery file, then http://localhost:8765/mcp."
        ),
    )
    parser.add_argument("--agents", type=int, default=4)
    parser.add_argument(
        "--requests-per-agent",
        type=int,
        default=100,
    )
    parser.add_argument(
        "--allow-non-loopback",
        action="store_true",
        help="Allow benchmarking a non-loopback endpoint. Disabled by default.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=300.0,
        help="Per socket operation timeout in seconds.",
    )
    parser.add_argument(
        "--query-prefix",
        default="Swift concurrency benchmark",
        help="Prefix used for DocumentationSearch query text.",
    )
    parser.add_argument(
        "--progress-interval",
        type=int,
        default=500,
        help="Print progress after this many completed responses. Use 0 to disable.",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> int:
    if args.agents < 1:
        raise BenchmarkError("--agents must be >= 1")
    if args.requests_per_agent < 1:
        raise BenchmarkError("--requests-per-agent must be >= 1")
    if args.timeout <= 0:
        raise BenchmarkError("--timeout must be > 0")
    if args.progress_interval < 0:
        raise BenchmarkError("--progress-interval must be >= 0")
    return args.agents * args.requests_per_agent


def resolve_endpoint(
    cli_endpoint: str | None,
    allow_non_loopback: bool,
) -> tuple[str, str]:
    if cli_endpoint:
        return cli_endpoint, "--endpoint"

    env_endpoint = non_empty(os.environ.get(ENDPOINT_ENV))
    if env_endpoint:
        return env_endpoint, ENDPOINT_ENV

    discovery_path = discovery_file_path()
    discovery_endpoint = read_discovery_endpoint(
        discovery_path,
        allow_non_loopback=allow_non_loopback,
    )
    if discovery_endpoint:
        return discovery_endpoint, f"discovery file: {discovery_path}"

    return DEFAULT_ENDPOINT, "fallback"


def discovery_file_path() -> str:
    override = non_empty(os.environ.get(DISCOVERY_FILE_ENV))
    if override:
        return os.path.expanduser(override)

    cache_root = non_empty(os.environ.get(CACHE_ROOT_ENV))
    if cache_root:
        root = os.path.expanduser(cache_root)
    else:
        root = os.path.expanduser("~/Library/Caches")
    return os.path.join(root, "XcodeMCPProxy", "endpoint.json")


def read_discovery_endpoint(
    path: str,
    allow_non_loopback: bool,
) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as file:
            record = json.load(file)
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None

    url = record.get("url")
    pid = record.get("pid")
    if not isinstance(url, str) or not url:
        return None
    if isinstance(pid, int) and not process_is_alive(pid):
        return None
    if not is_loopback_url(url):
        if allow_non_loopback:
            return url
        raise BenchmarkError(
            "refusing to benchmark a non-loopback discovery endpoint; pass "
            "--allow-non-loopback to override"
        )
    return url


def process_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def is_loopback_url(raw_url: str) -> bool:
    parsed = urllib.parse.urlparse(raw_url)
    host = parsed.hostname
    if host is None:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def non_empty(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


def parse_endpoint(raw_url: str, allow_non_loopback: bool) -> Endpoint:
    parsed = urllib.parse.urlparse(raw_url)
    if parsed.scheme != "http":
        raise BenchmarkError(f"only http endpoints are supported: {raw_url}")
    if parsed.hostname is None:
        raise BenchmarkError(f"endpoint host is missing: {raw_url}")
    if not allow_non_loopback and not is_loopback_url(raw_url):
        raise BenchmarkError(
            "refusing to benchmark a non-loopback endpoint; pass "
            "--allow-non-loopback to override"
        )

    try:
        parsed_port = parsed.port
    except ValueError as error:
        raise BenchmarkError(f"endpoint port is invalid: {raw_url}") from error
    port = parsed_port if parsed_port is not None else 80
    if port <= 0:
        raise BenchmarkError(f"endpoint port must be greater than 0: {raw_url}")
    path = parsed.path or "/"
    target = path
    if parsed.query:
        target += f"?{parsed.query}"

    host_header = parsed.hostname
    if ":" in host_header and not host_header.startswith("["):
        host_header = f"[{host_header}]"
    if port != 80:
        host_header = f"{host_header}:{port}"

    return Endpoint(
        url=raw_url,
        host=parsed.hostname,
        port=port,
        target=target,
        host_header=host_header,
    )


async def read_headers(
    reader: asyncio.StreamReader,
    timeout: float,
) -> dict[str, str]:
    headers: dict[str, str] = {}
    while True:
        line = await asyncio.wait_for(reader.readline(), timeout=timeout)
        if line in (b"\r\n", b"\n", b""):
            return headers
        decoded = line.decode("iso-8859-1").rstrip("\r\n")
        if ":" not in decoded:
            continue
        name, value = decoded.split(":", 1)
        headers[name.lower()] = value.strip()


async def read_body(
    reader: asyncio.StreamReader,
    headers: dict[str, str],
    timeout: float,
) -> bytes:
    content_length = headers.get("content-length")
    if content_length is None:
        return await asyncio.wait_for(reader.read(), timeout=timeout)
    try:
        length = int(content_length)
    except ValueError as error:
        raise BenchmarkError(f"invalid Content-Length: {content_length}") from error
    return await asyncio.wait_for(reader.readexactly(length), timeout=timeout)


def parse_status(raw_line: bytes) -> int:
    line = raw_line.decode("iso-8859-1").strip()
    parts = line.split(" ", 2)
    if len(parts) < 2 or not parts[1].isdigit():
        raise BenchmarkError(f"invalid HTTP status line: {line}")
    return int(parts[1])


def decode_json(data: bytes) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        snippet = data[:240].decode("utf-8", errors="replace")
        raise BenchmarkError(f"response was not JSON: {snippet}") from error
    if not isinstance(value, dict):
        raise BenchmarkError(f"response JSON was not an object: {compact(value)}")
    return value


async def run_agent(
    agent_index: int,
    endpoint: Endpoint,
    requests_per_agent: int,
    timeout: float,
    query_prefix: str,
    progress: Progress,
    start_barrier: StartBarrier,
) -> AgentResult:
    agent_started = time.monotonic()
    connect_started = time.monotonic()
    connection = await HTTPConnection.open(endpoint, timeout)
    connect_seconds = time.monotonic() - connect_started
    session_id: str | None = None
    try:
        initialize_started = time.monotonic()
        try:
            session_id = await initialize_agent(agent_index, connection)
        except SessionBoundError as error:
            session_id = error.session_id
            raise
        initialize_seconds = time.monotonic() - initialize_started

        await start_barrier.wait()
        request_started_at = time.monotonic()
        request_latencies = await run_agent_requests(
            agent_index=agent_index,
            connection=connection,
            session_id=session_id,
            requests_per_agent=requests_per_agent,
            query_prefix=query_prefix,
            progress=progress,
        )
        request_finished_at = time.monotonic()
        request_seconds = request_finished_at - request_started_at

        total_seconds = time.monotonic() - agent_started
        return AgentResult(
            agent_index=agent_index,
            connect_seconds=connect_seconds,
            initialize_seconds=initialize_seconds,
            request_started_at=request_started_at,
            request_finished_at=request_finished_at,
            request_seconds=request_seconds,
            total_seconds=total_seconds,
            request_latencies=request_latencies,
        )
    except Exception:
        await start_barrier.abort()
        raise
    finally:
        if session_id is not None:
            await delete_session_best_effort(
                agent_index=agent_index,
                endpoint=endpoint,
                session_id=session_id,
                timeout=timeout,
            )
        await connection.close()


async def run_agent_requests(
    agent_index: int,
    connection: HTTPConnection,
    session_id: str,
    requests_per_agent: int,
    query_prefix: str,
    progress: Progress,
) -> list[float]:
    latencies: list[float] = []
    for request_index in range(requests_per_agent):
        request_id = documentation_search_request_id(agent_index, request_index)
        started = time.monotonic()
        connection.write_json(
            payload=documentation_search_payload(
                id=request_id,
                agent_index=agent_index,
                request_index=request_index,
                query_prefix=query_prefix,
            ),
            session_id=session_id,
            close=False,
        )
        await connection.flush()
        response = await connection.read_response()
        completed_at = time.monotonic()
        ensure_json_rpc_success(response.body, request_id)
        result = response.body.get("result")
        if isinstance(result, dict) and result.get("isError") is True:
            raise BenchmarkError(
                f"agent {agent_index} request {request_index} tool error: "
                f"{compact(result)}"
            )
        latencies.append(completed_at - started)
        progress.record()
    return latencies


async def initialize_agent(agent_index: int, connection: HTTPConnection) -> str:
    request_id = agent_index + 1
    connection.write_json(
        payload={
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "clientInfo": {
                    "name": f"XcodeMCPKitLiveBenchmarkAgent{agent_index}",
                    "version": "dev",
                },
                "capabilities": {},
            },
        },
        session_id=None,
        close=False,
    )
    await connection.flush()
    response = await connection.read_raw_response()
    session_id = response.headers.get(SESSION_HEADER.lower())
    if not 200 <= response.status <= 299:
        raise SessionBoundError(f"HTTP {response.status}", session_id)
    try:
        body = decode_json(response.body)
    except BenchmarkError as error:
        raise SessionBoundError(str(error), session_id) from error
    try:
        ensure_json_rpc_success(body, request_id)
    except BenchmarkError as error:
        raise SessionBoundError(str(error), session_id) from error
    if not session_id:
        raise BenchmarkError(
            f"agent {agent_index} initialize response did not include {SESSION_HEADER}"
        )
    return session_id


async def delete_session_best_effort(
    agent_index: int,
    endpoint: Endpoint,
    session_id: str,
    timeout: float,
) -> None:
    try:
        connection = await HTTPConnection.open(endpoint, timeout)
        try:
            connection.write_delete(session_id=session_id, close=True)
            await connection.flush()
            response = await connection.read_raw_response()
            if not 200 <= response.status <= 299:
                print(
                    f"warning: agent {agent_index} session delete returned "
                    f"HTTP {response.status}",
                    file=sys.stderr,
                )
        finally:
            await connection.close()
    except Exception as error:
        print(
            f"warning: failed to delete agent {agent_index} session: {error}",
            file=sys.stderr,
        )


def documentation_search_payload(
    id: int,
    agent_index: int,
    request_index: int,
    query_prefix: str,
) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": {
            "name": "DocumentationSearch",
            "arguments": {
                "query": f"{query_prefix} agent {agent_index} request {request_index}",
            },
        },
    }


def documentation_search_request_id(agent_index: int, request_index: int) -> int:
    return (agent_index + 1) * 1_000_000 + request_index


def ensure_json_rpc_success(body: dict[str, Any], request_id: int) -> None:
    if body.get("id") != request_id:
        raise BenchmarkError(
            f"response id mismatch: expected {request_id}, got {body.get('id')!r}"
        )
    if "error" in body:
        raise BenchmarkError(f"JSON-RPC error: {compact(body['error'])}")


def compact(value: Any) -> str:
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(text) > 400:
        return text[:397] + "..."
    return text


async def run(args: argparse.Namespace) -> None:
    total = validate_args(args)
    endpoint_url, endpoint_source = resolve_endpoint(
        args.endpoint,
        allow_non_loopback=args.allow_non_loopback,
    )
    endpoint = parse_endpoint(
        endpoint_url,
        allow_non_loopback=args.allow_non_loopback,
    )

    print(f"endpoint: {endpoint.url} ({endpoint_source})")
    print(
        "load: "
        f"{args.agents} agents x {args.requests_per_agent} closed-loop requests "
        f"= {total} total"
    )

    progress = Progress(total=total, interval=args.progress_interval)
    start_barrier = StartBarrier(parties=args.agents)
    tasks = [
        asyncio.create_task(
            run_agent(
                agent_index=agent_index,
                endpoint=endpoint,
                requests_per_agent=args.requests_per_agent,
                timeout=args.timeout,
                query_prefix=args.query_prefix,
                progress=progress,
                start_barrier=start_barrier,
            )
        )
        for agent_index in range(args.agents)
    ]
    try:
        results = await asyncio.gather(*tasks)
    except Exception:
        await start_barrier.abort()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        raise

    print_benchmark_summary(total, results)


def print_benchmark_summary(
    total: int,
    results: list[AgentResult],
) -> None:
    latencies = [
        latency
        for result in results
        for latency in result.request_latencies
    ]
    request_started_at = min((result.request_started_at for result in results), default=0.0)
    request_finished_at = max((result.request_finished_at for result in results), default=0.0)
    request_elapsed = max(0.0, request_finished_at - request_started_at)
    rate = total / request_elapsed if request_elapsed > 0 else 0.0

    print("")
    print("benchmark summary")
    print(f"  requests: {total}")
    print(f"  agents: {len(results)}")
    print(f"  request wall time: {format_seconds(request_elapsed)}")
    print(f"  throughput: {rate:.1f} req/s")
    print("  request latency:")
    print(f"    min: {format_seconds(min(latencies))}")
    print(f"    p50: {format_seconds(percentile(latencies, 50))}")
    print(f"    p90: {format_seconds(percentile(latencies, 90))}")
    print(f"    p95: {format_seconds(percentile(latencies, 95))}")
    print(f"    p99: {format_seconds(percentile(latencies, 99))}")
    print(f"    max: {format_seconds(max(latencies))}")
    print("  per-agent:")
    for result in sorted(results, key=lambda item: item.agent_index):
        agent_rate = len(result.request_latencies) / result.request_seconds
        print(
            f"    agent {result.agent_index}: "
            f"connect={format_seconds(result.connect_seconds)}, "
            f"initialize={format_seconds(result.initialize_seconds)}, "
            f"requests={format_seconds(result.request_seconds)}, "
            f"total={format_seconds(result.total_seconds)}, "
            f"throughput={agent_rate:.1f} req/s, "
            f"p50={format_seconds(percentile(result.request_latencies, 50))}, "
            f"p95={format_seconds(percentile(result.request_latencies, 95))}, "
            f"max={format_seconds(max(result.request_latencies))}"
        )


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * (percentile_value / 100.0)
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = rank - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def format_seconds(value: float) -> str:
    if value < 1:
        return f"{value * 1_000:.1f}ms"
    return f"{value:.3f}s"


def main() -> int:
    try:
        asyncio.run(run(parse_args()))
    except KeyboardInterrupt:
        print("cancelled", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
