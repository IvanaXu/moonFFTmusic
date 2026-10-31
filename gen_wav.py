#!/usr/bin/env python3
"""Generate a test WAV file with a 440Hz sine wave (2 seconds, 16-bit PCM, 44100Hz)."""

import struct
import math
import sys

def generate_wav(filename, frequency=440.0, duration=2.0, sample_rate=44100, amplitude=0.8):
    """Generate a WAV file with a sine wave at the given frequency."""
    num_samples = int(sample_rate * duration)

    # WAV header
    bits_per_sample = 16
    num_channels = 1
    byte_rate = sample_rate * num_channels * bits_per_sample // 8
    block_align = num_channels * bits_per_sample // 8
    data_size = num_samples * block_align
    file_size = 36 + data_size

    with open(filename, 'wb') as f:
        # RIFF header
        f.write(b'RIFF')
        f.write(struct.pack('<I', file_size))
        f.write(b'WAVE')

        # fmt chunk
        f.write(b'fmt ')
        f.write(struct.pack('<I', 16))  # chunk size
        f.write(struct.pack('<H', 1))   # audio format (PCM)
        f.write(struct.pack('<H', num_channels))
        f.write(struct.pack('<I', sample_rate))
        f.write(struct.pack('<I', byte_rate))
        f.write(struct.pack('<H', block_align))
        f.write(struct.pack('<H', bits_per_sample))

        # data chunk
        f.write(b'data')
        f.write(struct.pack('<I', data_size))

        # Write sine wave samples
        for i in range(num_samples):
            # Generate sine wave with slight harmonic for richer spectrum
            t = i / sample_rate
            sample = amplitude * math.sin(2.0 * math.pi * frequency * t)
            # Add a second harmonic at half amplitude
            sample += 0.3 * amplitude * math.sin(2.0 * math.pi * frequency * 2 * t)
            # Add a third harmonic
            sample += 0.15 * amplitude * math.sin(2.0 * math.pi * frequency * 3 * t)
            # Clamp and convert to 16-bit
            sample = max(-1.0, min(1.0, sample))
            int_sample = int(sample * 32767)
            f.write(struct.pack('<h', int_sample))

    print(f"Generated: {filename}")
    print(f"  Frequency: {frequency}Hz, Duration: {duration}s")
    print(f"  Sample rate: {sample_rate}Hz, Samples: {num_samples}")
    print(f"  File size: {file_size + 8} bytes")

if __name__ == '__main__':
    output = sys.argv[1] if len(sys.argv) > 1 else 'test.wav'
    freq = float(sys.argv[2]) if len(sys.argv) > 2 else 440.0
    generate_wav(output, frequency=freq)
