#!/usr/bin/env python3
"""Exercise the real TUI and one-shot client together, using temporary projects."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import pty
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

BINARY = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/corral").resolve())


class Tui:
    def __init__(self, root):
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen([BINARY], cwd=root, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        self.output = bytearray()
        self.reader = threading.Thread(target=self.drain, daemon=True)
        self.reader.start()

    def drain(self):
        while True:
            try:
                self.output.extend(os.read(self.master, 65536))
            except OSError:
                return

    def close(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=10)
        self.reader.join(timeout=2)
        os.close(self.master)
        assert self.proc.returncode == 0, self.output.decode(errors="replace")[-2000:]


def call(root, *args, ok=True, code=None):
    result = subprocess.run([BINARY, "agent", *args], cwd=root, capture_output=True, text=True, timeout=7)
    body = json.loads(result.stdout)
    assert result.stderr == "", result.stderr
    assert body["ok"] == ok, body
    assert result.returncode == (0 if ok else code or 1), (result.returncode, body)
    return body


def wait_for(root, name, predicate):
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        task = call(root, "show", name)["task"]
        if predicate(task):
            return task
        time.sleep(0.03)
    raise AssertionError(task)


def wait_ready(root):
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        result = subprocess.run([BINARY, "agent", "list"], cwd=root, capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
        time.sleep(0.03)
    raise AssertionError(result.stdout)


with tempfile.TemporaryDirectory(prefix="corral-agent-test-") as tmp:
    root = Path(tmp)
    nested = root / "nested"
    nested.mkdir()
    (root / "broken").mkdir()
    (root / "broken/corral.json").write_text("{")
    (root / "corral.json").write_text(json.dumps({"tasks": {
        "web": "printf '\\033[31mhello 世界\\033[0m\\n'; exec sleep 60",
        "finish": "printf 'one\\ntwo\\nthree\\n'; exit 7",
        "grace": {"shell": "trap '' TERM; printf 'ready\\n'; while :; do sleep 1; done"},
    }}))
    (nested / "corral.json").write_text(json.dumps({"tasks": {"web": "exec sleep 60"}}))

    missing = call(root, "list", ok=False)
    assert missing["error"]["code"] == "instance_not_running"
    assert "human" in missing["error"]["message"]
    assert not list(root.glob("*.sock"))
    call(root, "stop", ok=False, code=2)
    call(root, "logs", "web", "--lines", "0", ok=False, code=2)
    tui = Tui(root)
    second = None
    try:
        listing = wait_ready(root)
        assert len(listing["tasks"]) == 4
        assert len(listing["config_errors"]) == 1
        assert all(t["status"] == "idle" and t["pid"] is None for t in listing["tasks"])
        ids = [t["id"] for t in listing["tasks"]]
        assert len(set(ids)) == 4
        assert len(call(root, "list", "--name", "web", "--status", "idle")["tasks"]) == 2
        assert len(call(root, "list", "--config", "nested")["tasks"]) == 1
        assert call(root, "start", "web", ok=False)["error"]["code"] == "ambiguous_task"
        assert all(t["pid"] is None for t in call(root, "list")["tasks"])
        assert call(root, "show", "missing", ok=False)["error"]["code"] == "task_not_found"
        web = call(root, "start", "web", "--config", ".")["task"]
        assert web["state"] == "running"
        assert call(root, "start", web["id"])["task"]["pid"] == web["pid"]
        deadline = time.monotonic() + 3
        while True:
            text = call(root, "logs", web["id"])["text"]
            if "hello 世界" in text:
                break
            assert time.monotonic() < deadline, text
        assert "\x1b" not in text
        assert len(call(root, "list", "--name", "web", "--state", "running")["tasks"]) == 1
        call(root, "restart", web["id"])
        wait_for(root, web["id"], lambda t: t["state"] == "running" and t["pid"] != web["pid"])
        call(root, "stop", web["id"])
        wait_for(root, web["id"], lambda t: t["state"] == "stopped")
        call(root, "start", "finish")
        finished = wait_for(root, "finish", lambda t: t["state"] == "stopped")
        assert finished["exit_code"] == 7 and finished["status"] == "exit"
        assert call(root, "logs", "finish", "--lines", "2")["text"] == "two\nthree"
        assert len(call(root, "list", "--status", "exit")["tasks"]) == 1

        # A raw partial request and a disappearing reader must not freeze the TUI.
        path = f"/tmp/corral-{os.getuid()}/{hashlib.sha256(str(root).encode()).hexdigest()}.sock"
        stalled = socket.socket(socket.AF_UNIX)
        stalled.connect(path)
        stalled.sendall(b'{"command":')
        gone = socket.socket(socket.AF_UNIX)
        gone.connect(path)
        gone.sendall(b'{"command":"list"}\n')
        gone.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            assert all(pool.map(lambda _: call(root, "list")["ok"], range(18)))
        stalled.close()
        assert os.stat(path).st_mode & 0o777 == 0o600
        assert os.stat(Path(path).parent).st_mode & 0o777 == 0o700

        # Agent access and child reaping continue while the human reads `w` output.
        os.write(tui.master, b"lw")
        time.sleep(0.1)
        assert b"press enter to return" in tui.output
        assert call(root, "list")["ok"]
        call(root, "start", "finish")
        wait_for(root, "finish", lambda t: t["state"] == "stopped")
        os.write(tui.master, b"\n")

        # Symlink aliases select the same canonical directory; children do not.
        alias = root / "alias"
        alias.symlink_to(root, target_is_directory=True)
        assert call(alias, "list")["root"] == str(root)
        assert call(nested, "list", ok=False)["error"]["code"] == "instance_not_running"
        second = Tui(nested)
        assert len(wait_ready(nested)["tasks"]) == 1
        duplicate = Tui(root)
        duplicate.proc.wait(timeout=5)
        duplicate.reader.join(timeout=2)
        os.close(duplicate.master)
        assert duplicate.proc.returncode == 1
        assert b"already running" in duplicate.output
        assert call(root, "list")["ok"]

        # A live but unresponsive instance gives a bounded, actionable error.
        tui.proc.send_signal(signal.SIGSTOP)
        try:
            unavailable = call(root, "list", ok=False)
            assert unavailable["error"]["code"] == "instance_unavailable"
            assert "human" in unavailable["error"]["message"]
        finally:
            tui.proc.send_signal(signal.SIGCONT)
        assert call(root, "list")["ok"]

        # Stop cancels a restart that is still waiting for the grace deadline.
        call(root, "start", "grace")
        deadline = time.monotonic() + 3
        while "ready" not in call(root, "logs", "grace")["text"]:
            assert time.monotonic() < deadline
        assert call(root, "restart", "grace")["task"]["restart_pending"]
        assert not call(root, "stop", "grace")["task"]["restart_pending"]
        wait_for(root, "grace", lambda t: t["state"] == "stopped")
    finally:
        if second:
            second.close()
        tui.close()
    assert call(root, "list", ok=False)["error"]["code"] == "instance_not_running"

    # A crash leaves a stale socket. Only a new human-mode launch cleans it up.
    tui = Tui(root)
    wait_ready(root)
    tui.proc.kill()
    tui.proc.wait(timeout=5)
    tui.reader.join(timeout=2)
    os.close(tui.master)
    assert Path(path).exists()
    assert call(root, "list", ok=False)["error"]["code"] == "instance_not_running"
    tui = Tui(root)
    try:
        assert len(wait_ready(root)["tasks"]) == 4
    finally:
        tui.close()
    assert not Path(path).exists()

print("Agent CLI integration tests passed")
