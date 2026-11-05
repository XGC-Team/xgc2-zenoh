#!/usr/bin/env python3
"""Exercise the installed Python SDK against a C++ peer over one UDP router."""
import json
import subprocess
import sys
import threading
import time

import zenoh


def wait_for(description, predicate, peer, timeout=12.0):
    deadline = time.monotonic() + timeout
    while not predicate():
        if peer.poll() is not None:
            raise RuntimeError("C++ peer exited while waiting for {}: {}".format(description, peer.returncode))
        if time.monotonic() >= deadline:
            raise RuntimeError("timeout waiting for " + description)
        time.sleep(0.01)


def main():
    cpp, endpoint, root = sys.argv[1:]
    zenoh.init_log_from_env_or("error")
    config = zenoh.Config()
    config.insert_json5("mode", '"client"')
    config.insert_json5("connect/endpoints", json.dumps([endpoint]))
    config.insert_json5("connect/timeout_ms", "5000")
    config.insert_json5("connect/exit_on_failure", "true")
    config.insert_json5("scouting/multicast/enabled", "false")
    config.insert_json5("scouting/gossip/enabled", "false")
    peer = None
    received_cpp = threading.Event()
    handled_cpp_query = threading.Event()
    errors = []
    query_python = root + "/query-python"

    def on_sample(sample):
        payload = sample.payload.to_bytes()
        if payload != b"cpp-pub":
            errors.append("unexpected C++ publication: {!r}".format(payload))
        received_cpp.set()

    def on_query(query):
        try:
            payload = None if query.payload is None else query.payload.to_bytes()
            if payload != b"cpp-request":
                errors.append("unexpected C++ query: {!r}".format(payload))
                return
            query.reply(query_python, b"python-reply")
            handled_cpp_query.set()
        except Exception as exc:
            errors.append("Python queryable failed: {!r}".format(exc))

    try:
        with zenoh.open(config) as session:
            subscriber = session.declare_subscriber(root + "/cpp-to-py", on_sample)
            queryable = session.declare_queryable(query_python, on_query)
            publisher = session.declare_publisher(
                root + "/py-to-cpp", reliability=zenoh.Reliability.BEST_EFFORT,
                congestion_control=zenoh.CongestionControl.DROP,
                priority=zenoh.Priority.REAL_TIME, express=True,
            )
            querier = session.declare_querier(root + "/query-cpp", timeout=5.0)
            peer = subprocess.Popen([cpp, endpoint, root], stdin=subprocess.PIPE, text=True)

            def ready():
                links = session.info.links()
                stream = any(link.is_streamed and link.reliability == zenoh.Reliability.RELIABLE for link in links)
                datagram = any(not link.is_streamed and link.reliability == zenoh.Reliability.BEST_EFFORT for link in links)
                return (stream and datagram and publisher.matching_status.matching and
                        querier.matching_status.matching)

            wait_for("mixed links and C++ subscriber/queryable", ready, peer)
            print("python: reliable stream and best-effort datagram links present", flush=True)
            # BEST_EFFORT permits an individual sample to be dropped.
            for _ in range(10):
                publisher.put(b"python-pub")
                time.sleep(0.01)
            replies = []
            for reply in querier.get(payload=b"python-request"):
                replies.append(reply.ok.payload.to_bytes())
            if replies != [b"cpp-reply"]:
                raise RuntimeError("unexpected C++ replies: {!r}".format(replies))
            wait_for("C++ publication and query", lambda: received_cpp.is_set() and handled_cpp_query.is_set() or bool(errors), peer)
            if errors:
                raise RuntimeError("; ".join(errors))
            peer.stdin.write("finish\n")
            peer.stdin.flush()
            code = peer.wait(timeout=10)
            if code:
                raise RuntimeError("C++ peer exited {}".format(code))
            print("python: C++->Python pub, Python->C++ pub, both query/reply payloads OK", flush=True)
            # Keep declarations alive through completion of the other process.
            _ = subscriber, queryable, publisher, querier
    finally:
        if peer is not None and peer.poll() is None:
            peer.terminate()
            try:
                peer.wait(timeout=3)
            except subprocess.TimeoutExpired:
                peer.kill()
                peer.wait()


if __name__ == "__main__":
    main()
