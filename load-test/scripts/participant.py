#!/usr/bin/env python3
"""
Single headless participant: Matrix login, join room, get LiveKit JWT via OpenID, connect to LiveKit, publish synthetic A/V.
Respects 429: retries after retry_after_ms (with cap).
"""
import asyncio
import json
import os
import sys
import time
from urllib.parse import urljoin

import requests

MAX_429_WAIT_SEC = 120
MAX_429_RETRIES = 15


# One sentence per 15s; rotate through these during the run
LOADTEST_SENTENCES = [
    "Load test participant sending a message.",
    "Audio and video are being published to the call.",
    "Matrix room message from the ramp test.",
    "Checking that the server handles mixed media and chat.",
    "This is a synthetic message every 15 seconds.",
    "Ramp test in progress; all participants should be under TX and RX load.",
    "If you see this in the room, the test is sending text as well as A/V.",
]


def _put_with_429_retry(url: str, *, headers=None, json_data=None, timeout=15) -> requests.Response:
    """PUT once or retry after 429 using retry_after_ms."""
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


def _post_with_429_retry(url: str, *, headers=None, json_data=None, timeout=15) -> requests.Response:
    """POST once or retry after 429 using retry_after_ms."""
    total_waited = 0.0
    for _ in range(MAX_429_RETRIES):
        r = requests.post(url, headers=headers or {}, json=json_data, timeout=timeout)
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

# Add parent so we can import fake_media
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_media import SAMPLES_PER_FRAME, SAMPLE_RATE, sine_audio_frames, video_frames

# LiveKit SDK
try:
    from livekit import rtc
except ImportError:
    rtc = None  # type: ignore


def matrix_join_room(server_url: str, access_token: str, room_id: str) -> None:
    """Join a Matrix room (e.g. after invite). Retries on 429."""
    r = _post_with_429_retry(
        urljoin(server_url, f"/_matrix/client/v3/rooms/{room_id}/join"),
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        json_data={},
        timeout=15,
    )
    r.raise_for_status()


def get_openid_token(server_url: str, access_token: str, user_id: str) -> dict:
    """Request OpenID token from Matrix (for lk-jwt-service). Retries on 429."""
    r = _post_with_429_retry(
        urljoin(server_url, f"/_matrix/client/v3/user/{user_id}/openid/request_token"),
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        json_data={},
        timeout=15,
    )
    r.raise_for_status()
    return r.json()


def matrix_send_message(server_url: str, access_token: str, room_id: str, body: str, txn_id: str) -> None:
    """Send one m.room.message to the room. Retries on 429."""
    url = urljoin(server_url, f"/_matrix/client/v3/rooms/{room_id}/send/m.room.message/{txn_id}")
    r = _put_with_429_retry(
        url,
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
        json_data={"msgtype": "m.text", "body": body},
        timeout=15,
    )
    r.raise_for_status()


def get_livekit_token(
    livekit_jwt_url: str,
    openid_resp: dict,
    room_id: str,
    user_id: str,
    server_name: str,
    device_id: str,
    member_id: str,
) -> str:
    """Exchange OpenID token for LiveKit JWT via lk-jwt-service (POST /get_token, SFURequest body)."""
    # lk-jwt-service exposes /get_token; nginx proxies /livekit/jwt/ -> upstream, so we need .../livekit/jwt/get_token
    url = livekit_jwt_url.rstrip("/") + "/get_token"
    openid_token = {
        "access_token": openid_resp.get("access_token") or openid_resp.get("token"),
        "token_type": openid_resp.get("token_type", "Bearer"),
        "matrix_server_name": openid_resp.get("matrix_server_name") or server_name,
        "expires_in": openid_resp.get("expires_in", 0),
    }
    body = {
        "room_id": room_id,
        "slot_id": "m.call#ROOM",
        "openid_token": openid_token,
        "member": {
            "id": member_id,
            "claimed_user_id": user_id,
            "claimed_device_id": device_id,
        },
    }
    r = _post_with_429_retry(url, headers={"Content-Type": "application/json"}, json_data=body, timeout=15)
    r.raise_for_status()
    data = r.json()
    return data.get("JWT") or data.get("jwt") or data.get("participant_token") or data.get("token") or str(data)


async def run_participant(
    server_url: str,
    server_name: str,
    livekit_ws_url: str,
    livekit_jwt_url: str,
    room_id: str,
    user_id: str,
    access_token: str,
    duration_seconds: float,
    safety_triggered: callable,
) -> None:
    if rtc is None:
        raise RuntimeError("livekit package not installed")

    # 1) Join Matrix room (accept invite)
    matrix_join_room(server_url, access_token, room_id)

    # 2) OpenID token from Matrix
    openid_resp = get_openid_token(server_url, access_token, user_id)
    if not (openid_resp.get("access_token") or openid_resp.get("token")):
        raise ValueError(f"No OpenID token in response: {openid_resp}")

    # 3) LiveKit JWT from lk-jwt-service (POST /get_token with SFURequest body)
    device_id = "LOADTEST"
    member_id = f"loadtest-{user_id}"
    lk_token = get_livekit_token(livekit_jwt_url, openid_resp, room_id, user_id, server_name, device_id, member_id)

    # 4) Connect to LiveKit
    room = rtc.Room()
    try:
        await room.connect(livekit_ws_url, lk_token)
    except Exception as e:
        raise RuntimeError(f"LiveKit connect failed: {e}") from e

    # 5) Create sources and tracks
    audio_source = rtc.AudioSource(SAMPLE_RATE, 1)
    audio_track = rtc.LocalAudioTrack.create_audio_track("sine", audio_source)
    video_source = rtc.VideoSource(320, 240)
    video_track = rtc.LocalVideoTrack.create_video_track("pattern", video_source)

    options = rtc.TrackPublishOptions()
    await room.local_participant.publish_track(audio_track, options)
    await room.local_participant.publish_track(video_track, options)

    # 5b) Wait for at least one remote to have subscribed audio and video (RX load)
    #    Skip when we are the only participant (no remotes).
    rx_timeout = 30.0
    rx_interval = 0.5
    elapsed = 0.0
    while elapsed < rx_timeout:
        has_audio = has_video = False
        for remote in room.remote_participants.values():
            for pub in remote.track_publications.values():
                if getattr(pub, "track", None) is None:
                    continue
                try:
                    k = getattr(pub, "kind", None)
                    if k == rtc.TrackKind.KIND_AUDIO:
                        has_audio = True
                    elif k == rtc.TrackKind.KIND_VIDEO:
                        has_video = True
                except Exception:
                    pass
        if room.remote_participants and (has_audio and has_video):
            break
        if not room.remote_participants:
            # Solo participant: no RX check required
            break
        await asyncio.sleep(rx_interval)
        elapsed += rx_interval
    if room.remote_participants and not (has_audio and has_video):
        await room.disconnect()
        raise RuntimeError(
            f"RX validation failed: after {rx_timeout}s no remote A/V received "
            "(need both subscribed audio and video from remotes)"
        )

    # 6) Matrix text: one sentence every 15s (run sync HTTP in executor)
    message_index = [0]  # mutable so closure can update

    def send_one_message():
        idx = message_index[0] % len(LOADTEST_SENTENCES)
        message_index[0] += 1
        body = LOADTEST_SENTENCES[idx]
        txn_id = f"loadtest-{user_id}-{int(time.time() * 1000)}"
        matrix_send_message(server_url, access_token, room_id, body, txn_id)

    async def text_loop():
        loop = asyncio.get_event_loop()
        while not safety_triggered():
            await loop.run_in_executor(None, send_one_message)
            for _ in range(150):  # 15s in 0.1s steps so we can check safety
                if safety_triggered():
                    return
                await asyncio.sleep(0.1)

    text_task = asyncio.create_task(text_loop())

    # 7) Push synthetic audio in a loop (async)
    async def push_audio():
        for chunk in sine_audio_frames():
            if safety_triggered():
                return
            frame = rtc.AudioFrame(chunk, SAMPLE_RATE, 1, SAMPLES_PER_FRAME)
            await audio_source.capture_frame(frame)
            await asyncio.sleep(0.02)  # ~20ms

    # 8) Push synthetic video in a loop (sync capture_frame)
    def push_video():
        import time as _t
        start = _t.monotonic()
        for raw in video_frames(320, 240, 15):
            if safety_triggered():
                return
            # VideoFrame(width, height, type, data) - type RGB24
            frame = rtc.VideoFrame(320, 240, rtc.VideoBufferType.RGB24, raw)
            ts_us = int((_t.monotonic() - start) * 1_000_000)
            video_source.capture_frame(frame, timestamp_us=ts_us)
            _t.sleep(1.0 / 15)

    async def run_video_loop():
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, push_video)

    audio_task = asyncio.create_task(push_audio())
    video_task = asyncio.create_task(run_video_loop())

    try:
        await asyncio.sleep(duration_seconds)
    finally:
        text_task.cancel()
        audio_task.cancel()
        video_task.cancel()
        for t in (text_task, audio_task, video_task):
            try:
                await t
            except asyncio.CancelledError:
                pass
        await room.disconnect()


def main() -> int:
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="config.yaml")
    p.add_argument("--user-index", type=int, required=True)
    p.add_argument("--duration", type=float, required=True)
    p.add_argument("--safety-file", default="")
    args = p.parse_args()

    def safety_triggered() -> bool:
        if not args.safety_file or not os.path.isfile(args.safety_file):
            return False
        try:
            with open(args.safety_file) as f:
                return f.read().strip().lower() == "1"
        except Exception:
            return False

    with open(args.config) as f:
        import yaml
        config = yaml.safe_load(f)

    users_file = config.get("test_users_file", "test_users.json")
    with open(users_file) as f:
        users = json.load(f)["users"]
    u = users[args.user_index]
    server_url = config["server_url"].rstrip("/")
    server_name = config.get("server_name", "timeways.net")
    livekit_ws_url = config["livekit_ws_url"]
    livekit_jwt_url = config["livekit_jwt_url"]
    room_id = os.environ.get("TEST_ROOM_ID") or config.get("test_room_id")
    if not room_id and os.path.isfile("test_room_id.txt"):
        with open("test_room_id.txt") as f:
            room_id = f.read().strip()
    if not room_id:
        print("Error: test_room_id not set and test_room_id.txt not found", file=sys.stderr)
        return 1

    asyncio.run(run_participant(
        server_url=server_url,
        server_name=server_name,
        livekit_ws_url=livekit_ws_url,
        livekit_jwt_url=livekit_jwt_url,
        room_id=room_id,
        user_id=u["user_id"],
        access_token=u["access_token"],
        duration_seconds=args.duration,
        safety_triggered=safety_triggered,
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
