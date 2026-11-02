#!/usr/bin/env python3
"""Generate a demo WAV file (2 seconds, 16-bit PCM, 44100Hz).

Modes:
  <freq>   — steady sine wave with harmonics (default 440Hz)
  chord    — steady mix of 220+440+880+2000 Hz
  music    — 120BPM 4-beat loop with kick, bass line, chord progression and
             hi-hats, plus a global crescendo so the spectrum actually moves
"""

import struct
import math
import os
import sys

# Frequencies of the demo chord: 220 + 440 + 880 + 2000 Hz
CHORD_FREQUENCIES = [220.0, 440.0, 880.0, 2000.0]

# 120BPM: 4 beats over 2.0 seconds
BEAT = 0.5  # seconds per beat

# One triad per beat: Am -> F -> C -> G
CHORD_PROGRESSION = [
    [220.00, 261.63, 329.63],   # Am
    [174.61, 220.00, 261.63],   # F
    [130.81, 164.81, 196.00],   # C (low voicing)
    [196.00, 246.94, 293.66],   # G
]

# Bass note per beat, walking under the chords
BASS_NOTES = [98.00, 87.31, 130.81, 98.00]  # G2 F2 C3 G2

# Lead melody, one note per half beat (8 notes)
MELODY = [587.33, 659.26, 783.99, 659.26, 587.33, 523.25, 440.00, 493.88]

# Per-beat crescendo so energy rises across the loop
BEAT_SWELL = [0.75, 0.85, 0.95, 1.05]


def write_wav(filename, samples, sample_rate):
    num_samples = len(samples)
    bits_per_sample = 16
    num_channels = 1
    byte_rate = sample_rate * num_channels * bits_per_sample // 8
    block_align = num_channels * bits_per_sample // 8
    data_size = num_samples * block_align
    file_size = 36 + data_size

    out_dir = os.path.dirname(os.path.abspath(filename))
    os.makedirs(out_dir, exist_ok=True)

    with open(filename, 'wb') as f:
        f.write(b'RIFF')
        f.write(struct.pack('<I', file_size))
        f.write(b'WAVE')
        f.write(b'fmt ')
        f.write(struct.pack('<I', 16))
        f.write(struct.pack('<H', 1))   # PCM
        f.write(struct.pack('<H', num_channels))
        f.write(struct.pack('<I', sample_rate))
        f.write(struct.pack('<I', byte_rate))
        f.write(struct.pack('<H', block_align))
        f.write(struct.pack('<H', bits_per_sample))
        f.write(b'data')
        f.write(struct.pack('<I', data_size))
        for s in samples:
            f.write(struct.pack('<h', int(max(-1.0, min(1.0, s)) * 32767)))

    print(f"Generated: {filename}")
    print(f"  Sample rate: {sample_rate}Hz, Samples: {num_samples}")
    print(f"  File size: {file_size + 8} bytes")


def generate_sine(frequency, duration, sample_rate, amplitude):
    """Steady sine with 2nd/3rd harmonics (or a chord mix for lists)."""
    num_samples = int(sample_rate * duration)
    out = []
    for i in range(num_samples):
        t = i / sample_rate
        if isinstance(frequency, list):
            sample = sum(amplitude * math.sin(2.0 * math.pi * f * t)
                         for f in frequency) * 0.25
        else:
            sample = amplitude * math.sin(2.0 * math.pi * frequency * t)
            sample += 0.3 * amplitude * math.sin(2.0 * math.pi * frequency * 2 * t)
            sample += 0.15 * amplitude * math.sin(2.0 * math.pi * frequency * 3 * t)
        out.append(sample)
    return out


def env_attack_decay(t, tau, attack=0.005):
    """Fast attack, exponential decay envelope."""
    if t < 0 or t >= tau * 8:
        return 0.0
    a = min(1.0, t / attack) if attack > 0 else 1.0
    return a * math.exp(-t / tau)


def generate_music(duration, sample_rate):
    """120BPM 4-beat loop: kick + bass + chords + hats, with dynamics."""
    num_samples = int(sample_rate * duration)
    out = [0.0] * num_samples
    num_beats = max(1, int(round(duration / BEAT)))

    for i in range(num_samples):
        t = i / sample_rate
        beat = int(t / BEAT)
        if beat >= num_beats:
            beat = num_beats - 1
        tb = t - beat * BEAT          # time since beat start
        swell = BEAT_SWELL[beat]
        s = 0.0

        # Kick: pitch-dropping sine thump on every beat
        s += 0.9 * env_attack_decay(tb, 0.07) * \
            math.sin(2.0 * math.pi * (60.0 - 18.0 * min(1.0, tb / 0.12)) * tb)

        # Bass note under each beat
        s += 0.42 * swell * env_attack_decay(tb, 0.35) * (
            math.sin(2.0 * math.pi * BASS_NOTES[beat] * tb) +
            0.5 * math.sin(2.0 * math.pi * BASS_NOTES[beat] * 2 * tb))

        # Chord triad per beat
        for f in CHORD_PROGRESSION[beat]:
            s += 0.17 * swell * env_attack_decay(tb, 0.30) * \
                math.sin(2.0 * math.pi * f * tb)

        # Lead melody: one note per half beat
        half = int(t / (BEAT / 2))
        if half < len(MELODY) * 2 // 2 and half < 8:
            th = t - half * (BEAT / 2)
            s += 0.16 * swell * env_attack_decay(th, 0.12) * \
                math.sin(2.0 * math.pi * MELODY[half] * th)

        # Hi-hat on the off-beats (bright short ping)
        if (int(t / (BEAT / 2)) % 2) == 1:
            th = t - (int(t / (BEAT / 2))) * (BEAT / 2)
            s += 0.2 * env_attack_decay(th, 0.045) * (
                math.sin(2.0 * math.pi * 7000.0 * th) +
                0.6 * math.sin(2.0 * math.pi * 9500.0 * th))

        # Global breathing swell + fade-in/out to avoid clicks
        s *= 0.8 + 0.15 * math.sin(2.0 * math.pi * 1.5 * t)
        fade_in = min(1.0, t / 0.015)
        fade_out = min(1.0, (duration - t) / 0.08)
        out[i] = s * fade_in * fade_out

    # Peak-normalize to leave headroom — summing layers can clip, and
    # clipped edges smear broadband distortion into the spectrum
    peak = max(1e-9, max(abs(v) for v in out))
    if peak > 0.92:
        g = 0.92 / peak
        out = [v * g for v in out]
    return out


def generate_wav(filename, frequency=440.0, duration=2.0, sample_rate=44100,
                 amplitude=0.8):
    if frequency == 'music':
        samples = generate_music(duration, sample_rate)
        write_wav(filename, samples, sample_rate)
        print(f"  Mode: music (120BPM loop, {duration}s)")
        return

    samples = generate_sine(frequency, duration, sample_rate, amplitude)
    write_wav(filename, samples, sample_rate)
    if isinstance(frequency, list):
        print(f"  Frequencies: {'+'.join(f'{f:g}Hz' for f in frequency)}, "
              f"Duration: {duration}s")
    else:
        print(f"  Frequency: {frequency}Hz, Duration: {duration}s")


if __name__ == '__main__':
    output = sys.argv[1] if len(sys.argv) > 1 else 'assets/test.wav'
    if len(sys.argv) > 2 and sys.argv[2].lower() == 'chord':
        freq = CHORD_FREQUENCIES
    elif len(sys.argv) > 2 and sys.argv[2].lower() == 'music':
        freq = 'music'
    else:
        freq = float(sys.argv[2]) if len(sys.argv) > 2 else 440.0
    generate_wav(output, frequency=freq)
