"""Compare Harbor's actual tmux PTY rendering with tmux's own pane contents.

Requires the already installed tmux; uses a fresh socket and no personal config,
network, SSH session, or credentials. Artifacts go into the supplied directory.
"""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
tmux = shutil.which("tmux")
if not tmux:
    sys.exit("tmux is required; this check does not install software")
replay = out / "terminal-replay"
subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(root / "app/.swift-module-cache"),
                str(root / "app/Localization.swift"), str(root / "app/LocalizationCatalog.swift"), str(root / "app/Mechanics.swift"), str(root / "app/TerminalMacroEvent.swift"), str(root / "app/Terminal.swift"),
                str(root / "app/tests/TerminalReplay.swift"), "-o", str(replay)], check=True)
socket_dir = tempfile.TemporaryDirectory(prefix="harbor-tmux-", dir="/tmp")
socket = str(Path(socket_dir.name) / "s")
env = dict(os.environ, TERM="xterm-256color", LANG="en_US.UTF-8")
env.pop("TMUX", None)
env.pop("TMUX_PANE", None)
master, slave = pty.openpty()
events = []

def size(rows, cols):
    events.append(dict(rows=rows, cols=cols))
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def command(*args):
    return subprocess.check_output([tmux, "-S", socket, *args], env=env, text=True, timeout=5)

def drain():
    # A quiet period after the last read lets tmux finish its batched repaint.
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if not select.select([master], [], [], 0.25)[0]:
            break
        data = os.read(master, 65536)
        if not data:
            break
        events.append(dict(data=base64.b64encode(data).decode()))

checks = []
def check(name, rows, cols, screenshot=False):
    drain()
    path = out / (name + ".json")
    path.write_text(json.dumps(events))
    args = [str(replay), str(path)]
    if screenshot:
        args.append(str(out / (name + ".png")))
    actual = json.loads(subprocess.check_output(args))
    pane = command("capture-pane", "-p", "-t", "check:0.0").splitlines()
    expected = [line.ljust(cols) for line in pane]
    assert len(expected) == rows - 1, (name, len(expected), rows)
    for row, line in enumerate(expected):
        assert actual[row] == line, (name, row, repr(actual[row]), repr(line))
    assert actual[-1].strip() == "HARBOR TMUX OK", (name, actual[-2:])
    assert sum("HARBOR TMUX OK" in line for line in actual) == 1, (name, "duplicated status")
    checks.append(name)
    print("PASS:", name)

try:
    size(12, 60)
    # cat echoes controlled output without reading any shell initialization files.
    client = subprocess.Popen([tmux, "-S", socket, "-f", "/dev/null", "new-session", "-s", "check", "/bin/cat"],
                              stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                              preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    deadline = time.monotonic() + 5
    while not Path(socket).exists() and client.poll() is None and time.monotonic() < deadline:
        drain()
    if not Path(socket).exists():
        drain()
        message = b"".join(base64.b64decode(event["data"]) for event in events if "data" in event).decode(errors="replace")
        (out / "startup.log").write_text(message)
        raise RuntimeError("tmux did not create its private socket: " + repr(message))
    command("set-option", "-g", "status-left", "HARBOR TMUX OK")
    command("set-option", "-g", "status-left-length", "40")
    command("set-option", "-g", "status-right", "")
    command("set-option", "-g", "window-status-current-format", "")
    command("set-option", "-g", "window-status-format", "")
    command("set-option", "-g", "status-style", "fg=black,bg=green")
    command("refresh-client")
    check("initial", 12, 60)
    os.write(master, b"".join((f"line-{i:02d}\n".encode() for i in range(35))))
    check("scrolling", 12, 60)
    for i in range(3):
        command("set-option", "-g", "status-style", "fg=black,bg=yellow" if i % 2 else "fg=black,bg=green")
        command("refresh-client")
        check(f"status-refresh-{i}", 12, 60)
    size(8, 44)
    time.sleep(0.2)
    check("shrink", 8, 44)
    size(15, 72)
    time.sleep(0.2)
    check("grow", 15, 72, screenshot=True)
    # Exercise a split separator and a full repaint before restoring one pane.
    command("split-window", "-h", "-t", "check:0", "/bin/cat")
    command("refresh-client")
    drain()
    path = out / "split.json"
    path.write_text(json.dumps(events))
    lines = json.loads(subprocess.check_output([str(replay), str(path), str(out / "split.png")]))
    assert any("│" in line for line in lines[:-1]), lines
    assert lines[-1].strip() == "HARBOR TMUX OK", lines[-1]
    print("PASS: split separator and status")
    command("kill-pane", "-t", "check:0.1")
    command("refresh-client")
    check("unsplit", 15, 72)
    (out / "result.json").write_text(json.dumps(dict(passed=checks + ["split separator and status"], tmux=command("-V").strip()), indent=2))
finally:
    if Path(socket).exists():
        subprocess.run([tmux, "-S", socket, "kill-server"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    if "client" in globals():
        try:
            client.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.kill()
            client.wait(timeout=5)
    os.close(master)
    os.close(slave)
    socket_dir.cleanup()
