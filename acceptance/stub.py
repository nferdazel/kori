#!/usr/bin/env python3
"""Test-only provider stub for the kori v1 acceptance suite.

Not a provider. One TCP listener, one canned behaviour per invocation, chosen by
--mode. Every accepted connection is appended to --count-file, and the last
request head+body is written to --capture-file, so a case can prove a leg was
never dialled and prove what bytes the gateway actually sent it.

Usage:
    python3 stub.py --port 18081 --mode 401 --count-file /tmp/c1 --capture-file /tmp/r1
"""

import argparse
import json
import os
import socket
import sys
import threading
import time

OK_BODY = {
    "id": "chatcmpl-stub",
    "object": "chat.completion",
    "created": 1763136000,
    "model": "stub-model",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "STUB-OK"},
            "finish_reason": "stop",
        }
    ],
    "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18},
}

OK_NOUSAGE_BODY = {k: v for k, v in OK_BODY.items() if k != "usage"}

GO_QUOTA_BODY = {
    "error": {
        "message": (
            "OpenCode Go usage limit reached (monthly, resets in 13d 15h). "
            "To keep going now, turn on Extra Usage or upgrade to Go Plus."
        ),
        "type": "GoUsageLimitError",
        "code": "GoUsageLimitError",
    }
}

PLAIN_429_BODY = {
    "error": {
        "message": "Rate limit reached for requests per minute (RPM).",
        "type": "requests",
        "code": "rate_limit_exceeded",
    }
}

MISSING_SESSION_BODY = {
    "error": {
        "message": "MissingSessionID",
        "type": "invalid_request_error",
        "code": "MissingSessionID",
    }
}

# One System One answer, in the shape commandcode returns it: `answers` is a
# question id keyed object, and the token counts are `input_tokens`/`output_tokens`
# (not the OpenAI `prompt_tokens`/`completion_tokens`).
SYSTEMONE_ANSWER_BODY = {
    "model": "typesafe/jev",
    "answers": {
        "who": {
            "type": "choice",
            "choice": "Bagas",
            "confidence": 0.76,
            "probabilities": {"Bagas": 0.76, "Fikri": 0.14, "Wulan": 0.10},
        }
    },
    "usage": {"input_tokens": 322, "output_tokens": 43},
}

SYSTEMONE_UNSUPPORTED_BODY = {
    "error": {
        "message": 'Model "typesafe/jev-latest" is not supported on this endpoint. '
                   "Use one of: typesafe/jev, typesafe/jev-1.14.0.",
        "type": "invalid_request_error",
    }
}

SYSTEMONE_INVALID_BODY = {
    "error": {
        "message": "Invalid input: expected record, received array",
        "type": "invalid_request_error",
        "param": "questions.q.criteria",
    }
}

BAD_MODEL_BODY = {
    "error": {
        "message": "model `flash` does not exist",
        "type": "invalid_request_error",
        "code": "model_not_found",
    }
}

STREAM_CHUNK_1 = (
    'data: {"id":"chatcmpl-stub","object":"chat.completion.chunk","created":1763136000,'
    '"model":"stub-model","choices":[{"index":0,"delta":{"role":"assistant","content":"STUB-"},'
    '"finish_reason":null}]}\n\n'
)
STREAM_CHUNK_2 = (
    'data: {"id":"chatcmpl-stub","object":"chat.completion.chunk","created":1763136000,'
    '"model":"stub-model","choices":[{"index":0,"delta":{"content":"OK"},"finish_reason":"stop"}]}\n\n'
)
STREAM_USAGE_CHUNK = (
    'data: {"id":"chatcmpl-stub","object":"chat.completion.chunk","created":1763136000,'
    '"model":"stub-model","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,'
    '"total_tokens":18}}\n\n'
)
STREAM_DONE = "data: [DONE]\n\n"


def dumps(obj):
    return json.dumps(obj, separators=(", ", ": ")).encode()


def body_bytes(obj, opts):
    """The canned body, with --model substituted when a case needs two legs to
    answer with different model names (A11). Non-streaming bodies only."""
    raw = dumps(obj)
    if opts.model:
        raw = raw.replace(b'"stub-model"', json.dumps(opts.model).encode())
    return raw


def dials_so_far(path):
    """How many connections this stub has accepted, including the current one."""
    if not path:
        return 0
    try:
        with open(path) as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def log_conn(path, note):
    if not path:
        return
    with open(path, "a") as fh:
        fh.write("%f %s\n" % (time.time(), note))


def capture(path, raw):
    """Last request wins. The temp name is unique per thread: eight concurrent
    requests sharing one temp file made a capture lose the race and the handler
    die before answering (A11d)."""
    if not path:
        return
    tmp = "%s.tmp.%d.%d" % (path, os.getpid(), threading.get_ident())
    try:
        with open(tmp, "wb") as fh:
            fh.write(raw)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def read_head(conn):
    """Read until end of headers. Returns (head_bytes, headers_dict, rest)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(65536)
        if not chunk:
            return buf, {}, b""
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()
    return head + b"\r\n\r\n", headers, rest


def read_body(conn, headers, rest, limit=4 * 1024 * 1024):
    try:
        want = int(headers.get("content-length", "0") or "0")
    except ValueError:
        want = 0
    body = rest
    while len(body) < want and len(body) < limit:
        chunk = conn.recv(65536)
        if not chunk:
            break
        body += chunk
    return body


def send(conn, status, content_type, body, extra=b""):
    reason = {
        200: "OK",
        400: "Bad Request",
        401: "Unauthorized",
        404: "Not Found",
        422: "Unprocessable Entity",
        429: "Too Many Requests",
        500: "Internal Server Error",
        502: "Bad Gateway",
        503: "Service Unavailable",
    }.get(status, "OK")
    head = (
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n" % (status, reason, content_type, len(body))
    ).encode() + extra
    conn.sendall(head + b"\r\n" + body)


def handle(conn, addr, opts):
    try:
        log_conn(opts.count_file, "%s:%d" % addr[:2])
        head, headers, rest = read_head(conn)
        body = read_body(conn, headers, rest)
        capture(opts.capture_file, head + body)
        mode = opts.mode

        # A3d: a provider that takes its time before the first byte, so a case can
        # prove which deadline the gateway actually applied to that body size.
        if opts.delay_headers > 0:
            time.sleep(opts.delay_headers)

        # A provider that only accepts one bearer: anything else is a 401, so a
        # case can prove which credential the gateway actually sent (A11).
        if opts.expect_bearer:
            if headers.get("authorization", "") != "Bearer " + opts.expect_bearer:
                send(conn, 401, "application/json",
                     dumps({"error": {"message": "Unauthorized"}}))
                try:
                    conn.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return

        # The token endpoint. One JSON answer per call; the count file is the
        # number of token calls this run made, so single flight is countable.
        if mode == "token":
            if opts.status != 200:
                send(conn, opts.status, "application/json",
                     dumps({"error": {"message": "token endpoint refused"}}))
            else:
                payload = {"access_token": opts.token, "token_type": "Bearer",
                           "expires_in": opts.token_ttl}
                if opts.rotate:
                    payload["refresh_token"] = opts.rotate
                send(conn, 200, "application/json", json.dumps(payload).encode())
            try:
                conn.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            return

        if mode == "never":
            deadline = time.time() + opts.ttl
            while time.time() < deadline:
                time.sleep(0.2)
            conn.close()
            return

        if mode == "never-body":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 200\r\n"
                b"Connection: close\r\n\r\n"
            )
            deadline = time.time() + opts.ttl
            while time.time() < deadline:
                time.sleep(0.2)
            conn.close()
            return

        if mode == "short-body":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: 200\r\n"
                b"Connection: close\r\n\r\n"
                b'{"id":"chatcmpl-stub","obj'
            )
            conn.shutdown(socket.SHUT_RDWR)
            conn.close()
            return

        if mode == "slow-chunks":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                b"Cache-Control: no-cache\r\n"
                b"Connection: close\r\n\r\n"
                + STREAM_CHUNK_1.encode()
            )
            deadline = time.time() + opts.gap
            while time.time() < deadline:
                time.sleep(0.2)
            try:
                conn.sendall(STREAM_CHUNK_2.encode() + STREAM_USAGE_CHUNK.encode() + STREAM_DONE.encode())
            except OSError:
                pass
            conn.close()
            return

        if mode == "ok":
            send(conn, 200, "application/json", body_bytes(OK_BODY, opts))
        elif mode == "ok-nousage":
            send(conn, 200, "application/json", body_bytes(OK_NOUSAGE_BODY, opts))
        elif mode == "systemone-ok":
            # The model the caller asked for is echoed back, so a case can prove
            # which id kori actually sent by reading the answer, not the log.
            payload = dict(SYSTEMONE_ANSWER_BODY)
            payload["model"] = opts.model or SYSTEMONE_ANSWER_BODY["model"]
            send(conn, 200, "application/json", json.dumps(payload).encode())
        elif mode == "systemone-unsupported":
            send(conn, 400, "application/json", dumps(SYSTEMONE_UNSUPPORTED_BODY))
        elif mode == "systemone-invalid":
            send(conn, 400, "application/json", dumps(SYSTEMONE_INVALID_BODY))
        elif mode == "ok-then-401":
            if dials_so_far(opts.count_file) > opts.after:
                send(conn, 401, "application/json", dumps({"error": {"message": "Unauthorized"}}))
            else:
                send(conn, 200, "application/json", body_bytes(OK_BODY, opts))
        elif mode == "401":
            send(conn, 401, "application/json", dumps({"error": {"message": "Unauthorized"}}))
        elif mode == "missing-session":
            send(conn, 400, "application/json", dumps(MISSING_SESSION_BODY))
        elif mode == "bad-request":
            send(conn, 400, "application/json", dumps(BAD_MODEL_BODY))
        elif mode == "503":
            send(conn, 503, "application/json", dumps({"error": {"message": "overloaded"}}))
        elif mode == "503-then-ok":
            # A13: one blip then health, so a retry can be seen to recover what
            # failover would have burned a whole leg for.
            if dials_so_far(opts.count_file) <= opts.after:
                send(conn, 503, "application/json", dumps({"error": {"message": "overloaded"}}))
            else:
                send(conn, 200, "application/json", body_bytes(OK_BODY, opts))
        elif mode == "502":
            send(conn, 502, "text/html", b"<html>bad gateway</html>")
        elif mode == "429-quota":
            send(conn, 429, "application/json", dumps(GO_QUOTA_BODY))
        elif mode == "429-plain":
            send(conn, 429, "application/json", dumps(PLAIN_429_BODY))
        elif mode == "stream-2-then-die":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                b"Cache-Control: no-cache\r\n"
                b"Connection: close\r\n\r\n"
                + STREAM_CHUNK_1.encode()
                + STREAM_CHUNK_2.encode()
            )
            conn.shutdown(socket.SHUT_RDWR)
            conn.close()
            return
        elif mode == "stream-ok":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                b"Cache-Control: no-cache\r\n"
                b"Connection: close\r\n\r\n"
                + STREAM_CHUNK_1.encode()
                + STREAM_CHUNK_2.encode()
                + STREAM_USAGE_CHUNK.encode()
                + STREAM_DONE.encode()
            )
        elif mode == "stream-2-no-usage":
            conn.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                b"Cache-Control: no-cache\r\n"
                b"Connection: close\r\n\r\n"
                + STREAM_CHUNK_1.encode()
                + STREAM_CHUNK_2.encode()
                + STREAM_DONE.encode()
            )
        elif mode in ("raw-toolcall", "raw-toolcall-stream"):
            name = opts.body_file
            ctype = "text/event-stream" if mode == "raw-toolcall-stream" else "application/json"
            with open(name, "rb") as fh:
                payload = fh.read()
            send(conn, 200, ctype, payload)
        elif mode == "raw":
            with open(opts.body_file, "rb") as fh:
                payload = fh.read()
            send(conn, opts.status, opts.content_type, payload)
        elif mode == "hangup":
            conn.close()
            return
        else:
            send(conn, 500, "text/plain", b"stub: unknown mode")
        try:
            conn.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--mode", required=True)
    ap.add_argument("--count-file", default="")
    ap.add_argument("--capture-file", default="")
    ap.add_argument("--body-file", default="")
    ap.add_argument("--status", type=int, default=200)
    ap.add_argument("--content-type", default="application/json")
    ap.add_argument("--ttl", type=float, default=180.0)
    ap.add_argument("--gap", type=float, default=119.0)
    # A3d: how long the stub waits before its first response byte, so a case can
    # prove which header deadline the gateway applied to that body size.
    ap.add_argument("--delay-headers", type=float, default=0.0)
    ap.add_argument("--model", default="")
    ap.add_argument("--after", type=int, default=0)
    # A11: the token endpoint's answer, and the one bearer a provider accepts.
    ap.add_argument("--token", default="STUB-ACCESS-TOKEN")
    ap.add_argument("--token-ttl", type=int, default=3600)
    ap.add_argument("--rotate", default="")
    ap.add_argument("--expect-bearer", default="")
    ap.add_argument("--host", default="127.0.0.1")
    opts = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((opts.host, opts.port))
    srv.listen(64)
    sys.stderr.write("stub %s on %s:%d\n" % (opts.mode, opts.host, opts.port))
    sys.stderr.flush()
    while True:
        conn, addr = srv.accept()
        t = threading.Thread(target=handle, args=(conn, addr, opts))
        t.daemon = True
        t.start()


if __name__ == "__main__":
    main()
