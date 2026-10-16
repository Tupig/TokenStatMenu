#!/usr/bin/env python3
"""Launches the real .app against a local fixture, with an isolated plist and test-only keys."""
import concurrent.futures
import http.client
import json
import os
import pathlib
import plistlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / ".integration"
BASE = "http://127.0.0.1:19876"
LOCAL_KEY = "integration-local-key"


def fetch(path, obj=None, key=LOCAL_KEY):
    data = None if obj is None else json.dumps(obj).encode()
    request = urllib.request.Request(BASE + path, data=data,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def snapshot():
    status, data = fetch("/tokenstat/status")
    assert status == 200
    return json.loads(data)


def body(model="fixture", stream=True):
    return {"model": model, "messages": [{"role": "user", "content": "integration prompt must not appear in logs"}], "stream": stream}


def wait_for(predicate, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise AssertionError("condition timed out")


def main():
    global WORK
    WORK.mkdir(exist_ok=True)
    WORK = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=WORK))
    (ROOT / ".integration/last-run.txt").write_text(str(WORK))
    config = {"dataSource": "proxy", "endpoint": "http://127.0.0.1:19877/v1/chat/completions", "port": 19876,
        "usageURL": "http://127.0.0.1:19877/usage", "refreshSeconds": 15.0,
        "inputPrice": 1.0, "outputPrice": 2.0, "loggingEnabled": True}
    with (WORK / "config.plist").open("wb") as handle:
        plistlib.dump(config, handle)
    codex_home = WORK / "codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "fixture"\nmodel = "fixture-model"\n[model_providers.fixture]\nbase_url = "http://127.0.0.1:19877/v1"\nwire_api = "responses"\nexperimental_bearer_token = "fixture-auth-must-not-be-imported"\n')
    server = subprocess.Popen([sys.executable, str(ROOT / "script/mock_server.py")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
    command = ["open", "-n", str(ROOT / "dist/TokenStatMenu.app"),
        "--env", "TOKENSTAT_LOCAL_KEY=" + LOCAL_KEY,
        "--env", "CODEX_HOME=" + str(codex_home),
        "--env", "TOKENSTAT_API_KEY=integration-upstream-key",
        "--env", "TOKENSTAT_USAGE_KEY=integration-quota-key",
        "--args", "--config", str(WORK / "config.plist"), "--show-panel", "--test-fixture",
        "--diagnostics-output", str(WORK / "ui-diagnostics.json")]
    subprocess.run(command, check=True)
    try:
        wait_for(lambda: fetch("/health")[0] == 200)
        diagnostic = WORK / "ui-diagnostics.json"
        ui = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())).get("quotaFraction") == 0.85 else None))
        assert ui["discoveredGateways"] == 1, ui
        assert "fixture-auth" not in diagnostic.read_text(), ui
        assert ui["fiveHourUsedPercent"] == 25 and ui["sevenDayUsedPercent"] == 70, ui
        assert ui["quotaUsed"] == 850000 and ui["alert"] == "yellow", ui
        assert ui["title"] == "测试 T:— · Σ— · 请求0" and ui["statusItemVisible"], ui
        assert ui["isTestFixture"] and not ui["hasRequestData"], ui
        assert "模拟测试" in ui["dataNotice"], ui
        assert snapshot()["requests"] == 0, "startup must not manufacture usage"
        assert fetch("/tokenstat/status", key="bad")[0] == 401
        assert fetch("/v1/chat/completions", body(), key="bad")[0] == 401
        assert fetch("/unsupported", body())[0] == 400
        assert snapshot()["requests"] == 0, "rejected local requests are not upstream requests"
        for route in ["/v1/chat/completions", "/v1/responses", "/api/chat", "/api/generate"]:
            status, data = fetch(route, body())
            assert status == 200 and "你好" in data.decode(), route
        assert fetch("/v1/chat/completions", body(stream=False))[0] == 200
        assert snapshot()["input"] == 500 and snapshot()["output"] == 250, snapshot()
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            jobs = [executor.submit(fetch, "/v1/chat/completions", body("slow")) for _ in range(3)]
            active = wait_for(lambda: (s if (s := snapshot())["active"] == 3 and s["outputTPS"] > 0 else None))
            assert active["estimatedRequests"] >= 3
            print("Live concurrent output TPS:", active["outputTPS"], flush=True)
            def live_title(value):
                title = value.get("title", "")
                if value.get("active") != 3 or not title.startswith("测试 T:≈") or "tok/s" not in title or "Σ" not in title:
                    return None
                speed = title.split("≈", 1)[1].split("tok/s", 1)[0]
                try:
                    return value if float(speed) > 0 else None
                except ValueError:
                    return None
            ui = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())) and live_title(r) else None))
            print("Actual AppKit menu title:", ui["title"], flush=True)
            for job in jobs:
                assert job.result()[0] == 200
        final = wait_for(lambda: (s if (s := snapshot())["active"] == 0 else None))
        assert final["input"] == 800 and final["output"] == 400, final
        assert abs(final["costUSD"] - 0.0016) < 1e-9
        assert final["outputTPS"] == 0
        for model, status in [("fail", 429), ("redirect", 302), ("incomplete", 200), ("malformed", 200)]:
            assert fetch("/v1/chat/completions", body(model))[0] == status
        failures = wait_for(lambda: (s if (s := snapshot())["failures"] == 4 else None))
        assert failures["requests"] == 12
        # Exercise inbound chunked HTTP as real clients such as SDK generators may use it.
        connection = http.client.HTTPConnection("127.0.0.1", 19876, timeout=20)
        data = json.dumps(body()).encode()
        connection.request("POST", "/v1/chat/completions", body=[data[:7], data[7:]],
            headers={"Authorization": "Bearer " + LOCAL_KEY, "Content-Type": "application/json"}, encode_chunked=True)
        response = connection.getresponse(); assert response.status == 200; response.read(); connection.close()
        final = wait_for(lambda: (s if (s := snapshot())["requests"] == 13 and s["active"] == 0 else None))
        assert final["failures"] == 4
        connection = http.client.HTTPConnection("127.0.0.1", 19876, timeout=20)
        connection.request("POST", "/v1/chat/completions", body=json.dumps(body("cancel")),
            headers={"Authorization": "Bearer " + LOCAL_KEY, "Content-Type": "application/json"})
        response = connection.getresponse(); response.read(100); response.close(); connection.close()
        cancelled = wait_for(lambda: (s if (s := snapshot())["active"] == 0 else None))
        assert cancelled["requests"] == 14 and cancelled["failures"] == 5, cancelled
        with urllib.request.urlopen("http://127.0.0.1:19877/fixture/quota95", timeout=2) as response:
            assert response.status == 200
        red = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())).get("alert") == "red" else None), timeout=20)
        assert red["quotaFraction"] == 0.96 and red["quotaUsed"] == 960000, red
        logs = WORK / "Logs/requests.jsonl"
        wait_for(lambda: logs.exists() and len(logs.read_text().splitlines()) >= 13)
        text = logs.read_text()
        for secret in ["integration prompt must not", "你好", LOCAL_KEY, "integration-upstream-key", "integration-quota-key"]:
            assert secret not in text, "logs must not contain bodies or secrets"
        records = [json.loads(line) for line in text.splitlines()]
        assert any(r["exact"] and r["input"] == 100 and r["output"] == 50 for r in records)
        print("PASS: real app, AppKit title, quota/yellow+red alerts, 4 routes, streaming/nonstreaming, 3 concurrent requests, usage correction, failures, cancellation, redirect refusal, chunked input, sanitized logs", flush=True)
        if "--keep-running" not in sys.argv:
            # A fresh normal launch must not inherit fixture quota or imply zero measured usage.
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            normal_config = WORK / "normal.plist"
            with normal_config.open("wb") as handle:
                plistlib.dump({"port": 19876, "dataSource": "proxy"}, handle)
            normal_diagnostic = WORK / "normal-ui.json"
            normal_command = command.copy()
            normal_command.remove("--test-fixture")
            normal_command[normal_command.index(str(WORK / "config.plist"))] = str(normal_config)
            normal_command[normal_command.index(str(diagnostic))] = str(normal_diagnostic)
            subprocess.run(normal_command, check=True)
            normal = wait_for(lambda: json.loads(normal_diagnostic.read_text()))
            assert normal["title"] == "T:— · Σ— · 请求0" and not normal["isTestFixture"], normal
            assert not normal["hasRequestData"] and "未采集" in normal["dataNotice"], normal
            assert normal.get("fiveHourUsedPercent") is None and normal.get("sevenDayUsedPercent") is None, normal
            assert normal.get("quotaUsed") is None and normal["alert"] == "normal", normal
            print("PASS: fixture clearly labeled; normal startup has no inherited usage or quota", flush=True)

            # Local-source startup uses an isolated CODEX_HOME fixture and never resolves proxy credentials.
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            local_home = WORK / "local-codex"
            session_dir = local_home / "sessions" / "2026" / "10" / "17"
            session_dir.mkdir(parents=True)
            session_meta = {"type": "session_meta", "payload": {
                "id": "12345678-1234-4234-8234-123456789abc", "source": "cli"}}
            event = {"timestamp": "2026-10-17T03:00:00Z", "type": "event_msg", "payload": {
                "type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 23, "output_tokens": 7, "total_tokens": 30}}, "rate_limits": {}}}
            (session_dir / "rollout-fixture-12345678-1234-4234-8234-123456789abc.jsonl").write_text(
                json.dumps(session_meta) + "\n" + json.dumps(event) + "\n")
            local_config = WORK / "local.plist"
            with local_config.open("wb") as handle:
                plistlib.dump({"port": 19879, "dataSource": "localCodex"}, handle)
            local_diagnostic = WORK / "local-ui.json"
            local_command = ["open", "-n", str(ROOT / "dist/TokenStatMenu.app"),
                "--env", "CODEX_HOME=" + str(local_home), "--args", "--config", str(local_config),
                "--test-fixture", "--disable-discovery", "--diagnostics-output", str(local_diagnostic)]
            subprocess.run(local_command, check=True)
            local = wait_for(lambda: (r if (r := json.loads(local_diagnostic.read_text())).get("hasRequestData") else None))
            assert local["title"] == "测试 上轮均:— · Σ30 · 1顶层对话" and local["isTestFixture"], local
            assert "模拟测试" in local["dataNotice"], local
            assert (local.get("quotaUsed") is None and local.get("fiveHourUsedPercent") is None
                and local.get("sevenDayUsedPercent") is None), local
            with socket.socket() as probe:
                probe.settimeout(0.5)
                assert probe.connect_ex(("127.0.0.1", 19879)) != 0, "local source must not start the proxy listener"
            print("PASS: synthetic nested local Codex startup is ready without proxy listener or inherited quota", flush=True)
        (WORK / "result.json").write_text(json.dumps(cancelled, indent=2))
        if "--keep-running" in sys.argv:
            print("Fixture running for UI inspection. PID", server.pid, flush=True)
            return
    finally:
        if "--keep-running" not in sys.argv:
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            server.terminate(); server.wait(timeout=5)


if __name__ == "__main__":
    main()
