#!/usr/bin/env python3
"""
Synthetic audio (sine wave) and video (test pattern) for headless LiveKit publishing.
"""
import math
import struct
import time
from typing import Iterator

import numpy as np

# Audio: 48kHz mono, 20ms frames (960 samples per frame)
SAMPLE_RATE = 48000
FRAME_DURATION_MS = 20
SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_DURATION_MS // 1000  # 960


def sine_audio_frames(hz: float = 440.0, num_channels: int = 1, amplitude: float = 0.5) -> Iterator[bytes]:
    """Generate PCM s16le frames (960 samples per channel). Mono or stereo (interleaved L,R)."""
    t = 0.0
    while True:
        samples_per_ch = []
        for _ in range(SAMPLES_PER_FRAME):
            v = int(32767 * amplitude * math.sin(2 * math.pi * hz * t))
            samples_per_ch.append(max(-32768, min(32767, v)))
            t += 1.0 / SAMPLE_RATE
        if num_channels == 1:
            yield struct.pack(f"<{len(samples_per_ch)}h", *samples_per_ch)
        else:
            # Stereo: interleaved L, R (same signal both channels)
            interleaved = []
            for s in samples_per_ch:
                interleaved.append(s)
                interleaved.append(s)
            yield struct.pack(f"<{len(interleaved)}h", *interleaved)


def video_frames(width: int = 320, height: int = 240, fps: int = 15) -> Iterator[bytes]:
    """Generate raw RGB24 frames (width * height * 3 bytes). Simple moving bar pattern. Constant rate (sleep 1/fps)."""
    t = 0
    frame_interval = 1.0 / fps
    while True:
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        frame[:, :] = (40, 40, 60)
        bar_w = max(4, width // 80)
        x = int((t % 1.0) * width) % width
        frame[:, max(0, x - bar_w) : min(width, x + bar_w)] = (80, 120, 200)
        yield frame.tobytes()
        t += frame_interval
        time.sleep(frame_interval)
