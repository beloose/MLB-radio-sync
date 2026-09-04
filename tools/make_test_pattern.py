#!/usr/bin/env python3
"""Generates RadioSync/Resources/TestPattern.wav, the loop used by the
"Test pattern" file source.

The pattern is a 10 s loop that tells you *where in the loop you are* by ear:
  second 0     : a 0.5 s 440 Hz tone (loop marker)
  second k=1..9: k short 1.2 kHz blips, 80 ms apart

So if you raise the delay by 3 s while "five blips" is playing, you should hear
the loop jump back to "two blips".

Usage: python3 tools/make_test_pattern.py
"""
import math
import os
import struct
import wave

SAMPLE_RATE = 24_000
SECONDS = 10
AMPLITUDE = 0.5
RAMP = 0.005  # seconds of fade at each edge of a tone, to avoid clicks

frames = [0.0] * (SAMPLE_RATE * SECONDS)


def tone(start, duration, frequency):
    first = int(start * SAMPLE_RATE)
    count = int(duration * SAMPLE_RATE)
    ramp = int(RAMP * SAMPLE_RATE)
    for i in range(count):
        envelope = 1.0
        if i < ramp:
            envelope = i / ramp
        elif i > count - ramp:
            envelope = (count - i) / ramp
        frames[first + i] += AMPLITUDE * envelope * math.sin(2 * math.pi * frequency * i / SAMPLE_RATE)


tone(0.0, 0.5, 440)
for second in range(1, 10):
    for blip in range(second):
        tone(second + blip * 0.08, 0.03, 1200)

out_path = os.path.join(os.path.dirname(__file__), "..", "RadioSync", "Resources", "TestPattern.wav")
with wave.open(os.path.normpath(out_path), "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(SAMPLE_RATE)
    wav.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, f)) * 32767)) for f in frames))
print("wrote", os.path.normpath(out_path))
