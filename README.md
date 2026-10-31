# moonFFTmusic

A real-time audio spectrum visualizer written in [MoonBit](https://www.moonbitlang.com/).
It reads a WAV file, performs Fast Fourier Transform (FFT) on audio chunks, and
displays a live frequency spectrum as a beautiful ANSI bar chart in the terminal.

## Features

- **WAV File Reader**: Parses RIFF/WAVE headers and reads 16-bit signed PCM audio
  (mono and stereo). Samples are normalized to [-1.0, 1.0].
- **Native FFT**: Implements the radix-2 Cooley-Tukey FFT algorithm entirely in
  MoonBit — no external libraries. Uses an iterative (non-recursive) implementation
  with bit-reversal permutation and butterfly operations for performance.
- **Hann Window**: Applies a Hann window function to each chunk before FFT to
  reduce spectral leakage at chunk boundaries.

### Beautiful Terminal Display

- **🌈 Rainbow Gradient**: 256-color ANSI codes create a smooth blue → cyan →
  green → yellow → orange → red → magenta gradient across frequency bars.
- **▁▂▃▄▅▆▇█ Partial Blocks**: 8x vertical sub-row resolution for smooth bar
  transitions — no more jagged tops.
- **📊 Log-spaced Frequency Mapping**: Low (bass) frequencies get more visual
  space, matching how human ears perceive sound.
- **📈 Peak Hold with Gravity Decay**: Peak markers linger and slowly fall,
  just like professional audio analyzers.
- **🔲 Box-drawing Header**: Bordered header showing title, sample rate, FFT
  size, dominant frequency, and time position.
- **📍 Frequency Axis Labels**: 50Hz, 100Hz, 200Hz, 500Hz, 1kHz, 2kHz, 5kHz,
  10kHz markers positioned under the correct bars.
- **🔊 RMS Volume Meter**: Real-time RMS level in dB with a horizontal bar.
- **⏳ Progress Bar**: Playback position with percentage and time display.
- **🎵 Dominant Frequency**: Detects and displays the peak frequency in real-time.

## Project Structure

```
moonFFTmusic/
├── moon.mod              # MoonBit module definition
├── src/
│   └── main/
│       ├── moon.pkg      # Package config (imports, target)
│       ├── main.mbt      # Main program (async loop, RMS, peak tracking)
│       ├── fft.mbt       # FFT implementation (Complex, FFT, Hann window)
│       ├── wav.mbt       # WAV file parser
│       └── display.mbt   # Terminal ANSI renderer (gradient, peaks, labels)
├── gen_wav.py            # Test WAV file generator (sine wave)
├── run.sh                # Build and run script
└── README.md             # This file
```

## Prerequisites

- MoonBit toolchain (`moon` CLI) — install from https://www.moonbitlang.com/download
- Python 3 (for generating test WAV files)

## Building

```bash
moon build --target native
```

## Running

```bash
# Run with a WAV file (default FFT size: 1024)
moon run src/main <wav_file>

# Run with custom FFT size (must be power of 2: 256, 512, 1024, 2048, ...)
moon run src/main <wav_file> 2048
```

## Quick Start

```bash
# 1. Generate a test WAV file (440Hz sine wave, 2 seconds)
python3 gen_wav.py test.wav 440.0

# 2. Build and run
./run.sh test.wav 1024
```

## Generating Test WAV Files

The `gen_wav.py` script creates a WAV file with a sine wave containing harmonics:

```bash
# Generate 440Hz (A4 note) test file
python3 gen_wav.py test.wav 440.0

# Generate 261.63Hz (C4 note) test file
python3 gen_wav.py test.wav 261.63
```

The generated file contains:
- Fundamental frequency at the specified Hz
- Second harmonic at 30% amplitude
- Third harmonic at 15% amplitude
- 2 seconds duration, 44100Hz sample rate, 16-bit PCM mono

## How It Works

1. **Read WAV**: The WAV file is read as raw bytes and parsed into normalized
   float samples.
2. **Chunk Processing**: Audio is processed in overlapping chunks (FFT size
   samples, 50% overlap).
3. **RMS Calculation**: Root mean square of the chunk is computed for the
   volume meter.
4. **Windowing**: A Hann window is applied to each chunk to reduce spectral
   leakage.
5. **FFT**: The radix-2 Cooley-Tukey FFT transforms the time-domain samples
   into the frequency domain.
6. **Magnitude**: The magnitude of each frequency bin is calculated.
7. **Peak Tracking**: Peak heights are updated with gravity decay for the
   peak hold effect.
8. **Display**: Magnitudes are mapped to bar heights using log-spaced frequency
   mapping and logarithmic magnitude scaling, then rendered as rainbow-gradient
   partial-block bars with peak markers, frequency labels, RMS meter, and
   progress bar.
9. **Refresh**: The display updates every 50ms, advancing through the audio.

## FFT Algorithm Details

The implementation uses the **iterative radix-2 Cooley-Tukey** algorithm:

- **Bit-reversal permutation**: Reorders samples into bit-reversed index order
- **Butterfly operations**: Combines pairs at increasing strides (2, 4, 8, ..., N)
- **Twiddle factors**: Complex roots of unity computed iteratively
- **Time complexity**: O(N log N)
- **Space complexity**: O(N) in-place

## License

MIT
