#!/usr/bin/env python3
"""
Create N test users via Synapse Admin API and optionally create the private E2EE test room
(invite-only; only admin_user_id + these bots). Writes test_users.json (user_id, password, access_token).
Idempotent: if test_users_file exists and has enough users, skips creation unless --force.
Respects 429: retries after retry_after_ms (with backoff cap).

Note: The 1c/1g limit is for the k8s test stack only. Run this on a capable host; use
--delay-between-users 0 or a small value when the server has relaxed rate limits (e.g. QA).
"""
import argparse
import json
import os
import secrets
import sys
import time
from urllib.parse import urljoin

import requests

# Cap total wait per request so we don't block forever (e.g. 5 min)
MAX_429_WAIT_SEC = 300
MAX_429_RETRIES = 20


def request_with_429_retry(
    method: str,
    url: str,
    *,
    headers=None,
    json_data=None,
    timeout=30,
) -> requests.Response:
    """Perform request; on 429 sleep retry_after_ms (respecting cap) and retry."""
    total_waited = 0.0
    retries = 0
    while True:
        if method.upper() == "PUT":
            r = requests.put(url, headers=headers, json=json_data, timeout=timeout)
        elif method.upper() == "POST":
            r = requests.post(url, headers=headers, json=json_data, timeout=timeout)
        else:
            raise ValueError(f"Unsupported method: {method}")
        if r.status_code != 429:
            return r
        retries += 1
        if retries > MAX_429_RETRIES:
            return r
        try:
            wait_ms = int(r.json().get("retry_after_ms", 5000))
        except Exception:
            wait_ms = 5000
        wait_sec = min(wait_ms / 1000.0, MAX_429_WAIT_SEC - total_waited)
        if wait_sec <= 0:
            return r
        print(f"429 rate limited; waiting {wait_sec:.1f}s (retry_after_ms={wait_ms}) before retry...", file=sys.stderr)
        time.sleep(wait_sec)
        total_waited += wait_sec


def load_config(config_path: str) -> dict:
    import yaml
    with open(config_path) as f:
        return yaml.safe_load(f)

def main() -> int:
    parser = argparse.ArgumentParser(description="Create test users and optional private E2EE room")
    parser.add_argument("--config", default="config.yaml", help="Config file path")
    parser.add_argument("--participants", type=int, help="Number of test users (overrides config)")
    parser.add_argument("--force", action="store_true", help="Recreate users even if file exists")
    parser.add_argument("--create-room-only", action="store_true", help="Only create room; do not create users")
    parser.add_argument("--delay-between-users", type=float, default=2.5, help="Seconds to wait between creating each user (0 = max parallel; use smaller with QA relaxed rate limits)")
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: {args.config} not found. Copy from config.example.yaml.", file=sys.stderr)
        return 1

    config = load_config(args.config)
    server_url = (os.environ.get("SERVER_URL") or config["server_url"]).rstrip("/")
    server_name = config["server_name"]
    admin_token = os.environ.get("ADMIN_ACCESS_TOKEN") or config.get("admin_access_token") or config.get("admin_api_token")
    if not admin_token:
        print("Error: set admin_access_token in config or ADMIN_ACCESS_TOKEN in env.", file=sys.stderr)
        return 1

    admin_user_id = config.get("admin_user_id", f"@lukano:{server_name}")
    n = args.participants or config.get("participants", 5)
    users_file = config.get("test_users_file", "test_users.json")
    headers = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}

    users = []
    if not args.create_room_only:
        existing = []
        if os.path.isfile(users_file) and not args.force:
            with open(users_file) as f:
                data = json.load(f)
                existing = data.get("users", [])
            if len(existing) >= n:
                print(f"Already have {len(existing)} users in {users_file}. Skipping user creation; will still create room if needed.")
                users = existing
        if not users:
            for i in range(1, n + 1):
                localpart = f"test-load-{i}"
                user_id = f"@{localpart}:{server_name}"
                password = secrets.token_urlsafe(24)
                # Optional stagger (use 0 or small value when server has relaxed rate limits, e.g. QA)
                if i > 1 and args.delay_between_users > 0:
                    time.sleep(args.delay_between_users)
                # Create user via Admin API (retry on 429)
                r = request_with_429_retry(
                    "PUT",
                    urljoin(server_url, f"/_synapse/admin/v2/users/{user_id}"),
                    headers=headers,
                    json_data={"password": password, "admin": False, "deactivated": False},
                    timeout=30,
                )
                if r.status_code not in (200, 201):
                    if r.status_code == 429:
                        return 1
                    if r.status_code == 409:
                        # User exists: update password via same PUT (Synapse allows update), then login
                        r2 = request_with_429_retry(
                            "PUT",
                            urljoin(server_url, f"/_synapse/admin/v2/users/{user_id}"),
                            headers=headers,
                            json_data={"password": password, "admin": False, "deactivated": False},
                            timeout=30,
                        )
                        if r2.status_code not in (200, 201):
                            print(f"Update user {user_id}: {r2.status_code} {r2.text}", file=sys.stderr)
                            return 1
                    else:
                        print(f"Create user {user_id}: {r.status_code} {r.text}", file=sys.stderr)
                        return 1
                # Login to get access_token (retry on 429)
                r = request_with_429_retry(
                    "POST",
                    urljoin(server_url, "/_matrix/client/v3/login"),
                    json_data={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": localpart}, "password": password},
                    timeout=30,
                )
                if r.status_code != 200:
                    print(f"Login {user_id}: {r.status_code} {r.text}", file=sys.stderr)
                    return 1
                token = r.json().get("access_token")
                users.append({"user_id": user_id, "password": password, "access_token": token})

            out = {"server_name": server_name, "users": users}
            with open(users_file, "w") as f:
                json.dump(out, f, indent=2)
            print(f"Created {len(users)} users in {users_file}")

    # Create private E2EE room if not test_room_id in config
    test_room_id = os.environ.get("TEST_ROOM_ID") or config.get("test_room_id")
    if test_room_id:
        print(f"Using existing test room: {test_room_id}")
        return 0

    # Create room as admin: private, encrypted, invite admin_user_id + bot user_ids (so lukano can join call)
    if args.create_room_only:
        if not os.path.isfile(users_file):
            print(f"Error: --create-room-only requires {users_file}", file=sys.stderr)
            return 1
        with open(users_file) as f:
            bot_user_ids = [u["user_id"] for u in json.load(f).get("users", [])]
    else:
        bot_user_ids = [u["user_id"] for u in users]
    # Invite only the bot users; the admin is the room creator and is already in the room (inviting them causes 403).
    invite_list = list(bot_user_ids)
    r = request_with_429_retry(
        "POST",
        urljoin(server_url, "/_matrix/client/v3/createRoom"),
        headers=headers,
        json_data={
            "visibility": "private",
            "preset": "private_chat",
            "name": "Load test (private)",
            "topic": "Automated A/V load test - do not join",
            "initial_state": [
                {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}},
            ],
            "invite": invite_list,
        },
        timeout=30,
    )
    if r.status_code != 200:
        print(f"Create room: {r.status_code} {r.text}", file=sys.stderr)
        return 1
    room_id = r.json().get("room_id")
    print(f"Created private E2EE room: {room_id}. Invited: {invite_list}.")
    # Write room id to config or a small state file so run_load_test can read it
    state_file = "test_room_id.txt"
    with open(state_file, "w") as f:
        f.write(room_id)
    print(f"Wrote {state_file}. Set test_room_id in config or TEST_ROOM_ID to reuse.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
