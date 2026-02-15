#!/usr/bin/env python3
"""
Tier 2 load test: N headless browsers join the same Element Call room with fake media,
stay for duration_sec, collect RTCPeerConnection.getStats() every 5s into results/webrtc_stats.jsonl.
Use a guest/public room URL so no auth is required, or pass tokens to join as users.
Usage:
  python tier2_element_call_playwright.py --room-url "https://call.element.io/!xxx:server" --participants 3 --duration 180
Requires: pip install playwright && playwright install chromium
"""
import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

try:
    from playwright.async_api import async_playwright
except ImportError:
    print("Install playwright: pip install playwright && playwright install chromium", file=sys.stderr)
    sys.exit(1)


# Inject before page loads so we capture all RTCPeerConnections
INIT_SCRIPT = """
window.__rtcPeerConnections = [];
const Orig = window.RTCPeerConnection;
window.RTCPeerConnection = function(...args) {
    const pc = new Orig(...args);
    window.__rtcPeerConnections.push(pc);
    return pc;
};
window.RTCPeerConnection.prototype = Orig.prototype;
"""


async def get_stats(page) -> list[dict] | None:
    """Collect getStats() from the page's RTCPeerConnections."""
    try:
        stats = await page.evaluate("""async () => {
            const results = [];
            const pcs = window.__rtcPeerConnections || [];
            for (let i = 0; i < pcs.length; i++) {
                const pc = pcs[i];
                try {
                    const s = await pc.getStats();
                    const out = {};
                    s.forEach(entry => { out[entry.id] = { type: entry.type, ...Object.fromEntries(entry) }; });
                    results.push({ id: 'pc-' + i, stats: out });
                } catch (e) {
                    results.push({ id: 'pc-' + i, error: String(e) });
                }
            }
            return results;
        }""")
        return stats
    except Exception as e:
        return [{"error": str(e)}]


async def run_participant(
    browser_type,
    room_url: str,
    participant_id: int,
    duration_sec: int,
    stats_interval: int,
    out_path: Path,
    tokens: list[str] | None,
) -> tuple[bool, float | None, float | None]:
    """Launch one browser context, join room with fake media, collect stats. Returns (joined_ok, avg_rtt_ms, packet_loss_pct)."""
    context = await browser_type.launch_persistent_context(
        user_data_dir=Path("/tmp") / f"playwright-call-{participant_id}",
        headless=True,
        args=[
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            "--no-sandbox",
        ],
        ignore_default_args=["--mute-audio"],
    )
    page = await context.new_page()
    await page.add_init_script(INIT_SCRIPT)
    joined = False
    start = time.monotonic()
    rtts: list[float] = []
    losses: list[float] = []

    try:
        await page.goto(room_url, wait_until="domcontentloaded", timeout=30000)
        await asyncio.sleep(3)
        # Try to click Join / Join call (common button texts)
        join_sel = "button:has-text('Join'), button:has-text('Join call'), [data-testid='join-call']"
        try:
            await page.click(join_sel, timeout=10000)
            joined = True
        except Exception:
            # Maybe already in call or different UI
            joined = True
        await asyncio.sleep(2)

        last_stats_time = time.monotonic()
        while time.monotonic() - start < duration_sec:
            stats = await get_stats(page)
            ts = time.time()
            with open(out_path, "a") as f:
                f.write(json.dumps({"ts_sec": ts, "participant_id": participant_id, "stats": stats}) + "\n")
            # Parse RTT and packet loss from stats if present
            if stats:
                for block in stats:
                    if isinstance(block.get("stats"), dict):
                        for v in block["stats"].values():
                            if isinstance(v, dict):
                                if "roundTripTime" in v:
                                    rtts.append(float(v["roundTripTime"]) * 1000)
                                if "packetsLost" in v and "packetsReceived" in v:
                                    recv = int(v.get("packetsReceived", 0) or 0)
                                    lost = int(v.get("packetsLost", 0) or 0)
                                    if recv + lost > 0:
                                        losses.append(100.0 * lost / (recv + lost))
            await asyncio.sleep(max(0, stats_interval - (time.monotonic() - last_stats_time)))
            last_stats_time = time.monotonic()
    except Exception as e:
        with open(out_path, "a") as f:
            f.write(json.dumps({"ts_sec": time.time(), "participant_id": participant_id, "error": str(e)}) + "\n")
    finally:
        await context.close()

    avg_rtt = sum(rtts) / len(rtts) if rtts else None
    avg_loss = sum(losses) / len(losses) if losses else None
    return joined, avg_rtt, avg_loss


async def main_async(args) -> int:
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tokens = None
    if args.tokens_file and Path(args.tokens_file).exists():
        with open(args.tokens_file) as f:
            data = json.load(f)
            users = data.get("users", [])
            tokens = [u.get("access_token") for u in users[: args.participants] if u.get("access_token")]

    async with async_playwright() as p:
        tasks = []
        for i in range(args.participants):
            tasks.append(
                run_participant(
                    p.chromium,
                    args.room_url,
                    i,
                    args.duration,
                    args.stats_interval,
                    out_path,
                    tokens,
                )
            )
        results = await asyncio.gather(*tasks, return_exceptions=True)
    joined = sum(1 for r in results if not isinstance(r, Exception) and r[0])
    success_rate = 100.0 * joined / args.participants if args.participants else 0
    rtts = [r[1] for r in results if not isinstance(r, Exception) and r[1] is not None]
    losses = [r[2] for r in results if not isinstance(r, Exception) and r[2] is not None]
    avg_rtt = sum(rtts) / len(rtts) if rtts else None
    avg_loss = sum(losses) / len(losses) if losses else None
    print(f"Join success: {joined}/{args.participants} ({success_rate:.1f}%)", file=sys.stderr)
    if avg_rtt is not None:
        print(f"Avg RTT: {avg_rtt:.1f} ms", file=sys.stderr)
    if avg_loss is not None:
        print(f"Avg packet loss: {avg_loss:.2f}%", file=sys.stderr)
    return 0 if joined >= args.participants * 0.9 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Tier 2: Playwright Element Call load test")
    parser.add_argument("--room-url", required=True, help="Element Call room URL (guest link or app URL)")
    parser.add_argument("--participants", type=int, default=3, help="Number of browser participants")
    parser.add_argument("--duration", type=int, default=180, help="Duration in seconds")
    parser.add_argument("--stats-interval", type=int, default=5, help="getStats() interval (seconds)")
    parser.add_argument("--output", default="results/webrtc_stats.jsonl", help="Output JSONL path")
    parser.add_argument("--tokens-file", help="Optional: test_users.json with access_token per user")
    args = parser.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
