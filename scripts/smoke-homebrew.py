#!/usr/bin/env python3
"""Exercise installed proxy and native-host MCP sessions using a disposable fixture."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import urllib.request


def message(identifier, method, params):
    body = dict(jsonrpc="2.0", method=method)
    if identifier is not None:
        body["id"] = identifier
    if params is not None:
        body["params"] = params
    return body


def result_of(reply, method):
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def stdio_client(process):
    async def request(identifier, method, params=None):
        process.stdin.write(json.dumps(message(identifier, method, params)).encode() + b"\n")
        await process.stdin.drain()
        if identifier is None:
            return None
        while line := await asyncio.wait_for(process.stdout.readline(), timeout=90):
            reply = json.loads(line)
            if reply.get("id") == identifier:
                return result_of(reply, method)
        raise RuntimeError(f"MCP process exited before answering {method}")
    return request


def http_client(endpoint):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    session = {}

    def post(identifier, method, params):
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if "id" in session:
            headers["Mcp-Session-Id"] = session["id"]
        body = json.dumps(message(identifier, method, params)).encode()
        with opener.open(urllib.request.Request(endpoint, data=body, headers=headers), timeout=90) as response:
            session.setdefault("id", response.headers.get("Mcp-Session-Id"))
            text = response.read().decode()
            if identifier is None:
                return None
            # A slow reply comes as an event stream that ends with the response.
            if response.headers.get_content_type() == "text/event-stream":
                replies = [json.loads(line[len("data:"):]) for line in text.splitlines() if line.startswith("data:")]
            else:
                replies = [json.loads(text)]
        return result_of(next(reply for reply in replies if reply.get("id") == identifier), method)

    async def request(identifier, method, params=None):
        return await asyncio.to_thread(post, identifier, method, params)
    return request


async def exercise(request, fixture):
    await request(1, "initialize", dict(protocolVersion="2025-06-18", capabilities={},
                                     clientInfo=dict(name="XcodeMCPKitHomebrewTest", version="1")))
    await request(None, "notifications/initialized")
    tools = await request(2, "tools/list")
    names = {tool["name"] for tool in tools["tools"]}
    if not {"XcodeRead", "XcodeListWorkspaces"} <= names:
        raise RuntimeError("Installed native backend is missing required headless tools")
    result = await request(3, "tools/call", dict(name="XcodeRead", arguments=dict(
        workspaceIdentifier=str(fixture / "ProxyToolVerifierFixture.xcodeproj"),
        filePath="ProxyToolVerifierFixture/VerifierCore.swift", limit=40)))
    if result.get("isError") or "VerifierCore" not in json.dumps(result):
        raise RuntimeError(f"Installed native backend could not read the fixture: {result}")


def verify_closed_pipes(executable, artifacts, environment):
    # A parent can exit with initialization queued and both output readers closed.
    with subprocess.Popen(
        [str(executable), "--artifacts-root", str(artifacts)], env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ) as process:
        try:
            process.stdin.write(json.dumps(dict(
                jsonrpc="2.0", id=1, method="initialize",
                params=dict(protocolVersion="2025-06-18", capabilities={},
                            clientInfo=dict(name="XcodeMCPKitDisconnectTest", version="1")),
            )).encode() + b"\n")
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
            try:
                status = process.wait(timeout=30)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError("Native helper survived stdin EOF with closed output pipes") from error
            if status not in (0, 1):
                raise RuntimeError(f"Native helper crashed after its parent disconnected: {status}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


async def verify(prefix, version, fixture_source):
    server = prefix / "bin/xcode-mcp-proxy-server"
    bundle = prefix / "libexec/XcodeMCPNativeHost.app"
    actual = subprocess.check_output([str(server), "--version"], text=True).strip()
    if actual != version:
        raise RuntimeError(f"{server.name}: expected {version}, got {actual}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    with tempfile.TemporaryDirectory(prefix="xcodemcp-homebrew-") as temporary:
        root = Path(temporary)
        fixture = root / "Fixture"
        shutil.copytree(fixture_source, fixture)
        discovery = root / "endpoint.json"
        environment = dict(os.environ, XCODE_MCP_PROXY_DISCOVERY_FILE=str(discovery),
                           XCODE_MCP_PROXY_CACHE_ROOT=str(root / "cache"))
        environment.pop("XCODE_MCP_NATIVE_HOST_BUNDLE", None)
        environment.pop("XCODE_MCP_PROXY_ENDPOINT", None)
        await asyncio.to_thread(verify_closed_pipes,
                                bundle / "Contents/MacOS/xcode-mcp-native-host",
                                root / "disconnect-artifacts", environment)
        processes = []
        with (root / "process.log").open("wb") as log:
            async def launch(*command):
                process = await asyncio.create_subprocess_exec(
                    *map(str, command), env=environment, stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE, stderr=log, start_new_session=True,
                    limit=16 * 1024 * 1024)
                processes.append(process)
                return process

            try:
                native = await launch(bundle / "Contents/MacOS/xcode-mcp-native-host",
                                      "--artifacts-root", root / "native-artifacts")
                await exercise(stdio_client(native), fixture)
                native.stdin.close()
                await asyncio.wait_for(native.wait(), timeout=30)
                if native.returncode:
                    raise RuntimeError(f"Native helper exited with {native.returncode}")
                proxy = await launch(server, "--host", "127.0.0.1", "--port", "0")
                async with asyncio.timeout(60):
                    while not discovery.exists():
                        if proxy.returncode is not None:
                            raise RuntimeError(f"Proxy exited with {proxy.returncode}")
                        await asyncio.sleep(0.05)
                endpoint = json.loads(discovery.read_text())["url"]
                await exercise(http_client(endpoint), fixture)
            except BaseException:
                log.flush()
                print((root / "process.log").read_text(errors="replace"), flush=True)
                raise
            finally:
                for process in reversed(processes):
                    if process.returncode is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            await asyncio.wait_for(process.wait(), timeout=15)
                        except TimeoutError:
                            os.killpg(process.pid, signal.SIGKILL)
                            await process.wait()
    print("Installed CLI version, native signature, early disconnect, direct MCP, and proxy MCP passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args()
    fixture = args.fixture or args.prefix / "share/xcode-mcpkit/ProxyToolVerifierFixture"
    asyncio.run(verify(args.prefix, args.version, fixture))


if __name__ == "__main__":
    main()
