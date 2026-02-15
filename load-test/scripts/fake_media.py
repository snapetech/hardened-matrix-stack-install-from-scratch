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


def sine_audio_frames(hz: float = 440.0) -> Iterator[bytes]:
    """Generate PCM s16le mono frames (960 samples = 1920 bytes per frame)."""
    t = 0.0
    while True:
        samples = []
        for _ in range(SAMPLES_PER_FRAME):
            v = int(32767 * 0.3 * math.sin(2 * math.pi * hz * t))
            samples.append(max(-32768, min(32767, v)))
            t += 1.0 / SAMPLE_RATE
        yield struct.pack(f"<{len(samples)}h", *samples)


def video_frames(width: int = 320, height: int = 240, fps: int = 15) -> Iterator[bytes]:
    """Generate raw RGB24 frames (width * height * 3 bytes). Simple moving bar pattern."""
    t = 0
    while True:
        frame = np.zeros((height, width, 3), dtype=np.uint8)
        # Background
        frame[:, :] = (40, 40, 60)
        # Moving bar
        x = int((t % 1.0) * width) % width
        frame[:, max(0, x - 10) : min(width, x + 10)] = (80, 120, 200)
        yield frame.tobytes()
        t += 1.0 / fps
        time.sleep(1.0 / fps)
