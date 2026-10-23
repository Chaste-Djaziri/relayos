# Path: src/laptop_bridge/approvals.py
"""Optional command-line fallback for reviewing SQLite-backed approvals."""
import argparse
import json

from .state import approve, deny, pending_requests, pending_oauth_authorizations, active_oauth_grants, active_permission_grants, revoke_permission_grant, decide_oauth_authorization, decide_request

def main():
    parser = argparse.ArgumentParser(description="Approve sensitive laptop actions locally")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("list-oauth")
    sub.add_parser("list-grants")
    sub.add_parser("list-permissions")
    sub.add_parser("list-pending-json")
    decide = sub.add_parser("decide-request")
    decide.add_argument("request_id")
    decide.add_argument("duration", choices=("once", "session", "persistent"))
    revoke_perm = sub.add_parser("revoke-permission")
    revoke_perm.add_argument("grant_id")
    oauth = sub.add_parser("decide-oauth")
    oauth.add_argument("request_id")
    oauth.add_argument("decision", choices=("approve", "deny"))
    approve = sub.add_parser("approve")
    approve.add_argument("request_id")
    args = parser.parse_args()
    if args.command == "list":
        for item in pending_requests():
            print(f"{item['request_id']}: {item['kind']} {item['target']} {item['argv']}")
        return
    if args.command == "list-oauth":
        print(json.dumps(pending_oauth_authorizations()))
        return
    if args.command == "list-grants":
        print(json.dumps(active_oauth_grants()))
        return
    if args.command == "list-permissions":
        print(json.dumps(active_permission_grants()))
        return
    if args.command == "list-pending-json":
        print(json.dumps(pending_requests()))
        return
    if args.command == "decide-request":
        decide_request(args.request_id, args.duration)
        return
    if args.command == "revoke-permission":
        revoke_permission_grant(args.grant_id)
        return
    if args.command == "decide-oauth":
        decide_oauth_authorization(args.request_id, args.decision == "approve")
        return
    item = next((item for item in pending_requests() if item["request_id"] == args.request_id), None)
    if item is None:
        raise SystemExit("Unknown or expired request")
    print(json.dumps({"action": item["kind"], "target": item["target"], "argv": item["argv"]}, indent=2))
    if input("Approve this exact action on THIS laptop? Type APPROVE: ").strip() != "APPROVE":
        deny(args.request_id)
        raise SystemExit("Denied")
    approve(args.request_id)
    print("Approved. Ask the MCP client to execute the request within five minutes.")


if __name__ == "__main__":
    main()
