# Path: src/laptop_bridge/approvals.py
"""Optional command-line fallback for reviewing SQLite-backed approvals."""
import argparse
import json

from .state import approve, deny, pending_requests, pending_oauth_authorizations, active_oauth_grants, active_permission_grants, revoke_permission_grant, decide_oauth_authorization, decide_request, emergency_stop, set_emergency_stop, saved_command_grants, revoke_command_grant, command_grant_duplicate_summary, cleanup_duplicate_command_grants

def main():
    parser = argparse.ArgumentParser(description="Approve sensitive laptop actions locally")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("list-oauth")
    sub.add_parser("list-grants")
    sub.add_parser("list-permissions")
    sub.add_parser("list-command-grants")
    sub.add_parser("command-grant-duplicates")
    sub.add_parser("cleanup-command-grant-duplicates")
    revoke_command = sub.add_parser("revoke-command-grant")
    revoke_command.add_argument("grant_id")
    sub.add_parser("list-pending-json")
    sub.add_parser("emergency-stop-status")
    set_stop = sub.add_parser("set-emergency-stop")
    set_stop.add_argument("state", choices=("true", "false", "on", "off"))
    decide = sub.add_parser("decide-request")
    decide.add_argument("request_id")
    decide.add_argument("duration", choices=("once", "session", "persistent", "deny"))
    revoke_perm = sub.add_parser("revoke-permission")
    revoke_perm.add_argument("grant_id")
    oauth = sub.add_parser("decide-oauth")
    oauth.add_argument("request_id")
    oauth.add_argument("decision", choices=("approve", "deny"))
    approve = sub.add_parser("approve")
    approve.add_argument("request_id")
    deny_parser = sub.add_parser("deny")
    deny_parser.add_argument("request_id")
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
    if args.command == "list-command-grants":
        print(json.dumps(saved_command_grants()))
        return
    if args.command == "command-grant-duplicates":
        print(json.dumps(command_grant_duplicate_summary()))
        return
    if args.command == "cleanup-command-grant-duplicates":
        print(json.dumps(cleanup_duplicate_command_grants()))
        return
    if args.command == "revoke-command-grant":
        revoke_command_grant(args.grant_id)
        print(json.dumps({"grant_id": args.grant_id, "revoked": True}))
        return
    if args.command == "list-pending-json":
        print(json.dumps(pending_requests()))
        return
    if args.command == "emergency-stop-status":
        print(json.dumps({"emergency_stop": emergency_stop()}))
        return
    if args.command == "set-emergency-stop":
        enabled = args.state.lower() in ("true", "on")
        set_emergency_stop(enabled)
        print(json.dumps({"emergency_stop": emergency_stop()}))
        return
    if args.command == "decide-request":
        decide_request(args.request_id, args.duration)
        return
    if args.command == "deny":
        deny(args.request_id)
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
