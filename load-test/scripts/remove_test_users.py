#!/usr/bin/env python3
"""
Deactivate test users listed in test_users.json via Synapse Admin API (PUT deactivated: true).
Call after a load test to clean up. Respects 429: retries after retry_after_ms.
"""
import argparse
import json
import os
import sys
import time
from urllib.parse import urljoin

import requests
import yaml

MAX_429_WAIT_SEC = 120
MAX_429_RETRIES = 15


def _put_with_429_retry(url: str, *, headers=None, json_data=None, timeout=15) -> requests.Response:
    total_waited = 0.0
    for _ in range(MAX_429_RETRIES):
        r = requests.put(url, headers=headers or {}, json=json_data, timeout=timeout)
        if r.status_code != 429:
            return r
        try:
            wait_ms = int(r.json().get("retry_after_ms", 5000))
        except Exception:
            wait_ms = 5000
        wait_sec = min(wait_ms / 1000.0, MAX_429_WAIT_SEC - total_waited)
        if wait_sec <= 0:
            return r
        time.sleep(wait_sec)
        total_waited += wait_sec
    return r


def load_config(config_path: str) -> dict:
    with open(config_path) as f:
        return yaml.safe_load(f)


def main() -> int:
    parser = argparse.ArgumentParser(description="Deactivate test users from test_users.json")
    parser.add_argument("--config", default="config.yaml", help="Config file path")
    parser.add_argument("--users-file", default="test_users.json", help="JSON file with users list")
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: {args.config} not found.", file=sys.stderr)
        return 1

    config = load_config(args.config)
    server_url = config["server_url"].rstrip("/")
    admin_token = os.environ.get("ADMIN_ACCESS_TOKEN") or config.get("admin_access_token") or config.get("admin_api_token")
    if not admin_token:
        print("Error: set admin_access_token in config or ADMIN_ACCESS_TOKEN in env.", file=sys.stderr)
        return 1

    if not os.path.isfile(args.users_file):
        print(f"Warning: {args.users_file} not found; nothing to remove.", file=sys.stderr)
        return 0

    with open(args.users_file) as f:
        users = json.load(f).get("users", [])
    if not users:
        return 0

    headers = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}
    for u in users:
        user_id = u.get("user_id")
        if not user_id:
            continue
        try:
            r = _put_with_429_retry(
                urljoin(server_url, f"/_synapse/admin/v2/users/{user_id}"),
                headers=headers,
                json_data={"deactivated": True},
                timeout=15,
            )
            if r.status_code in (200, 201):
                print(f"Deactivated {user_id}")
            else:
                print(f"Deactivate {user_id}: {r.status_code} {r.text}", file=sys.stderr)
        except Exception as e:
            print(f"Deactivate {user_id}: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
