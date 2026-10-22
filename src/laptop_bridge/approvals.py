# Path: src/laptop_bridge/approvals.py
"""Explicit local approvals. CLI tool is a prototype, not remote authorization."""
import argparse
import json
import os
import secrets
import time
from pathlib import Path
from .config import PENDING_FILE, STATE_DIR

TTL = 300

def _read():
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        return json.loads(PENDING_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}

def _write(data):
    temp = PENDING_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    try:
        temp.chmod(0o600)
    except OSError:
        pass
    os.replace(temp, PENDING_FILE)

def request(kind, details):
    data = _read()
    token = secrets.token_urlsafe(18)
    data[token] = {"kind": kind, "details": details, "created": time.time(), "approved": False}
    _write(data)
    return token

def consume(token):
    data = _read()
    item = data.pop(token, None)
    _write(data)
    if not item or not item["approved"] or time.time() - item["created"] > TTL:
        raise PermissionError("Missing, expired, or unapproved request")
    return item

def main():
    parser = argparse.ArgumentParser(description="Approve sensitive laptop actions locally")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    approve = sub.add_parser("approve")
    approve.add_argument("request_id")
    args = parser.parse_args()
    data = _read()
    if args.command == "list":
        for token, item in data.items():
            if time.time() - item["created"] <= TTL:
                print(f"{token}: {item['kind']} {item['details']} approved={item['approved']}")
        return
    item = data.get(args.request_id)
    if item is None or time.time() - item["created"] > TTL:
        raise SystemExit("Unknown or expired request")
    print(json.dumps({"action": item["kind"], "details": item["details"]}, indent=2))
    if input("Approve this exact action on THIS laptop? Type APPROVE: ").strip() != "APPROVE":
        raise SystemExit("Denied")
    item["approved"] = True
    _write(data)
    print("Approved. Ask the MCP client to execute the request within five minutes.")
