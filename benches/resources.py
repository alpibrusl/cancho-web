#!/usr/bin/env python3
"""What each implementation of the users API costs when it is not busy: start-up time and resident memory (docs/benchmarks.md).

    python3 benches/resources.py [rounds]       # needs build/users, build/go_users, build/floor (benches/run.sh builds them)

For each server, `rounds` times (default 5): the time from `exec` until the first `GET /health` is answered, then its resident memory (VmRSS,
summed over the process and everything it started, so a uvicorn master and its workers count) at four moments:
  idle         right after it answers
  loaded       after 1,000 users were created through it
  100 idle     with 100 more keep-alive connections held open and silent
  after a run  its high-water mark (VmHWM, the largest the process ever was) after 20,000 requests on 16 connections
Medians. Servers are not pinned: this is about size, not speed.
"""
import http.client
import json
import os
import socket
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
BUILD = os.path.join(ROOT, "build")
rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
BODY = json.dumps({"name": "Ada Lovelace", "email": "ada@example.org", "age": 36, "role": "admin", "tags": ["math", "code"]})
HDR = {"Content-Type": "application/json"}

SERVERS = [
    ("cancho users", [os.path.join(BUILD, "users"), "{port}"], None),
    ("Go net/http", [os.path.join(BUILD, "go_users"), "{port}"], None),
    ("C floor (hand-written epoll)", [os.path.join(BUILD, "floor"), "{port}"], None),
    ("FastAPI lean, uvloop + httptools", [sys.executable, "-m", "uvicorn", "app:app", "--port", "{port}", "--loop", "uvloop", "--http", "httptools"],
     (os.path.join(HERE, "fastapi_users"), {"LEAN": "1"})),
    ("FastAPI lean, 2 workers", [sys.executable, "-m", "uvicorn", "app:app", "--port", "{port}", "--loop", "uvloop", "--http", "httptools", "--workers", "2"],
     (os.path.join(HERE, "fastapi_users"), {"LEAN": "1"})),
]


def children(pid):
    out = [pid]
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                with open("/proc/%s/stat" % d) as f:
                    stat = f.read()
                ppid = int(stat[stat.rindex(")") + 2:].split()[1])
            except (OSError, ValueError):
                continue
            if ppid == pid:
                out.extend(children(int(d)))
    return out


def status_kb(pid, key):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def rss(pid, key="VmRSS"):
    return sum(status_kb(p, key) for p in children(pid))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(cmd, extra):
    port = free_port()
    argv = [a.replace("{port}", str(port)) for a in cmd]
    cwd, env_add = (extra if extra else (None, {}))
    env = dict(os.environ, **env_add)
    t0 = time.perf_counter()
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    while True:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                c.close()
                break
        except OSError:
            time.sleep(0.002)
        if time.perf_counter() - t0 > 30:
            raise SystemExit("did not start: %s" % argv)
    return proc, port, (time.perf_counter() - t0) * 1000


def stop(proc):
    try:
        os.killpg(proc.pid, 15)
    except ProcessLookupError:
        pass
    proc.wait()
    time.sleep(0.3)


def create(port, n):
    c = http.client.HTTPConnection("127.0.0.1", port)
    for _ in range(n):
        c.request("POST", "/users", BODY, HDR)
        c.getresponse().read()
    c.close()


def burst(port, total=20000, conns=16):
    import threading
    each = total // conns

    def work():
        c = http.client.HTTPConnection("127.0.0.1", port)
        for _ in range(each):
            c.request("GET", "/users/1")
            c.getresponse().read()
        c.close()
    ts = [threading.Thread(target=work) for _ in range(conns)]
    [t.start() for t in ts]
    [t.join() for t in ts]


def mib(kb):
    return "%.1f" % (kb / 1024)


print("%-36s %10s %9s %9s %10s %12s" % ("median of %d" % rounds, "start-up", "idle", "loaded", "100 idle", "after a run"))
print("%-36s %10s %9s %9s %10s %12s" % ("", "ms", "MiB", "MiB", "MiB", "peak MiB"))
for name, cmd, extra in SERVERS:
    ups, idle, loaded, held, peak = [], [], [], [], []
    for _ in range(rounds):
        proc, port, ms = start(cmd, extra)
        time.sleep(0.5)
        ups.append(ms)
        idle.append(rss(proc.pid))
        create(port, 1000)
        loaded.append(rss(proc.pid))
        socks = [socket.create_connection(("127.0.0.1", port)) for _ in range(100)]
        time.sleep(0.3)
        held.append(rss(proc.pid))
        for s in socks:
            s.close()
        burst(port)
        peak.append(rss(proc.pid, "VmHWM"))
        stop(proc)
    m = statistics.median
    print("%-36s %10.0f %9s %9s %10s %12s" % (name, m(ups), mib(m(idle)), mib(m(loaded)), mib(m(held)), mib(m(peak))))
