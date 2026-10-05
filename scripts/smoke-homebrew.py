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


async def request(process, identifier, method, params=None):
    message = dict(jsonrpc="2.0", method=method)
    if identifier is not None:
        message["id"] = identifier
    if params is not None:
        message["params"] = params
    process.stdin.write(json.dumps(message).encode() + b"\n")
    await process.stdin.drain()
    if identifier is None:
        return None
    while line := await asyncio.wait_for(process.stdout.readline(), timeout=90):
        result = json.loads(line)
        if result.get("id") != identifier:
            continue
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]
    raise RuntimeError(f"MCP process exited before answering {method}")


async def exercise(process, fixture):
    await request(process, 1, "initialize", dict(protocolVersion="2025-06-18", capabilities={},
                                              clientInfo=dict(name="XcodeMCPKitHomebrewTest", version="1")))
    await request(process, None, "notifications/initialized")
    # GUI tools can be ready before the independent headless host finishes starting.
    async with asyncio.timeout(60):
        while True:
            tools = await request(process, 2, "tools/list")
            names = {tool["name"] for tool in tools["tools"]}
            if {"XcodeRead", "XcodeListWorkspaces"} <= names:
                break
            await asyncio.sleep(0.1)
    result = await request(process, 3, "tools/call", dict(name="XcodeRead", arguments=dict(
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
    adapter = prefix / "bin/xcode-mcp-proxy"
    bundle = prefix / "libexec/XcodeMCPNativeHost.app"
    for executable in (server, adapter):
        actual = subprocess.check_output([str(executable), "--version"], text=True).strip()
        if actual != version:
            raise RuntimeError(f"{executable.name}: expected {version}, got {actual}")
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
                await exercise(native, fixture)
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
                client = await launch(adapter, "--url", endpoint)
                await exercise(client, fixture)
                client.stdin.close()
                await asyncio.wait_for(client.wait(), timeout=30)
                if client.returncode:
                    raise RuntimeError(f"STDIO adapter exited with {client.returncode}")
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
    print("Installed CLI versions, native signature, early disconnect, direct MCP, and proxy MCP passed.")


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
