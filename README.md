# moonFFTmusic

[![CI](https://github.com/IvanaXu/moonFFTmusic/actions/workflows/ci.yml/badge.svg)](https://github.com/IvanaXu/moonFFTmusic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A real-time audio spectrum visualizer written in [MoonBit](https://www.moonbitlang.com/).
It reads a WAV file, performs Fast Fourier Transform (FFT) on audio chunks, and
displays a live frequency spectrum as a beautiful ANSI bar chart in the terminal.

## Features

### Audio Engine

- **WAV File Reader**: Parses RIFF/WAVE headers and reads 16-bit signed PCM audio
  (mono and stereo). Samples are normalized to [-1.0, 1.0].
- **FFT Engine**: Iterative radix-2 Cooley-Tukey FFT with precomputed twiddle
  factors and in-place butterfly operations. Uses `unsafe_get`/`unsafe_set` for
  hot-loop performance.
- **Hann Window**: Applied before FFT to reduce spectral leakage, using
  `Array::mapi_in_place` for efficient in-place computation.

### Visual Display (16 enhancements)

| # | Feature | Description |
|---|---------|-------------|
| 1 | Attack/release envelope | Fast rise (0.7), slow fall (0.15) — natural amplitude decay |
| 2 | Spatial smoothing | 3-tap blur `[0.2, 0.6, 0.2]` across neighboring bars |
| 3 | Row-level brightness gradient | 3D glow effect — top of bars brighter, bottom dimmer |
| 4 | Left-side dB scale | Professional meter labels: 0dB, -12, -24, -36, -48 |
| 5 | Segmented RMS meter | Green (<60%) → yellow (<85%) → red zones with dB readout |
| 6 | Peak hold markers | Bold `━` with exponential decay (×0.88 per frame) |
| 7 | Separator line | `──` between header and spectrum area |
| 8 | Musical note detection | Shows note name + octave + cents (e.g., `A#4+`, `A3-`) |
| 9 | Bar grouping | Subtle gap every 3 bars for cleaner visual separation |
| 10 | Bottom glow reflection | 3-row dim mirror of spectrum with fading intensity |
| 11 | Dashed reference line | `┄` pattern at -12dB, `·` at gap positions |
| 12 | Bar caps | `▀` character at topmost cell for sealed-top look |
| 13 | Peak frequency marker | Yellow `▼` arrow above dominant frequency bar |
| 14 | Vertical frequency grid | Faint `╎` at label positions (50Hz – 10kHz) |
| 15 | Magnitude-based color | Brightness = 50% row position + 50% magnitude ratio |
| 16 | 26-color rainbow gradient | Blue → cyan → green → yellow → orange → red → magenta |

## How to Run

### Prerequisites

Install the MoonBit CLI:

```bash
# Unix (Linux / macOS)
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

# Verify installation
moon version
```

### Method 1: One-command script (easiest)

```bash
cd moonFFTmusic

# Generate a 440Hz test tone and visualize it
./run.sh

# Specify a WAV file and FFT size
./run.sh chord.wav 1024
```

The script automatically generates a test WAV if the file doesn't exist,
builds the project, and starts the visualizer.

### Method 2: Manual commands (most control)

```bash
cd moonFFTmusic

# Step 1: Generate a test WAV file
python3 gen_wav.py test.wav 440.0        # 440Hz sine wave (A4)
python3 gen_wav.py chord.wav chord        # Chord: 220+440+880+2000Hz

# Step 2: Build the project
moon build --target native

# Step 3: Run the visualizer
moon run src/main test.wav 1024
```

### Method 3: Run the compiled binary directly

```bash
cd moonFFTmusic
moon build --target native

# Binary location after build
./_build/native/debug/build/src/main/main.exe test.wav 1024
```

### Using your own WAV files

Any 16-bit PCM WAV file works:

```bash
moon run src/main /path/to/your/song.wav 2048
```

### Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `wav_file` | Yes | — | Path to a 16-bit PCM WAV file |
| `fft_size` | No | `1024` | FFT window size, must be power of 2 |

Valid FFT sizes: `256`, `512`, `1024`, `2048`, `4096`, `8192`, ...

Larger FFT sizes give better frequency resolution but slower time response.
Smaller sizes give better time resolution but coarser frequency bins.

### What you'll see

```
╔══════════════════════════════════════════════════════════════════╗
║ 🎵 MoonFFTmusic — Real-time Spectrum Analyzer                    ║
║ Rate: 44100Hz | FFT: 1024 | Bars: 60 | Peak: 473Hz (A#4+) | 0:0.2 ║
╚══════════════════════════════════════════════════════════════════╝
──────────────────────────────────────────────────────────────────
     ╎                            ▼     ╎        ╎      ╎
 0dB ╎                            ╎     ╎        ╎      ╎
│   ╎                            ╎     ╎        ╎      ╎
│   ╎┄┄·┄┄·┄┄·┄┄·┄┄·┄┄·┄┄·┄┄·┄┄·╎┄·┄┄·╎┄┄·┄┄·┄╎┄·┄┄·┄┄·┄╎
│   ╎          ▂▀ ▀▀▀ ▂▅ ▀▇    ▆     ╎        ╎      ╎
│   ╎          ▀█ ███ █▀ █▀    ▀     ╎▅       ╎      ╎
│   ╎       ▁▅ ██ ██ ███ █▀  ▃ █▃    ╎█       ╎      ╎
│   ▆▆ ▆▆ ▆█ ██ ██ ███ ███ ██▀ ███ ▂ ╎██▂ ▂▂  ╎▂▂ ▂▂ ╎▂▂▂
     ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀
     ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀▀ ▀
      50Hz   100Hz 200Hz    500Hz  1kHz  2kHz     5kHz   10kHz

RMS: [████████████████░░░░] -6.0 dB
║║║║║║║║║║║║║║║║║║║║║║║║║║▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 44%  0:0.2 / 0:0.5
```

Press `Ctrl+C` to stop.

## MoonBit Language Features

This project leverages MoonBit-specific features for performance and safety:

| Feature | Usage |
|---------|-------|
| `derive(Debug)` | Auto-generated debug output for `Complex` and `WavData` structs |
| `Array::unsafe_get`/`unsafe_set` | Bypass bounds check in FFT butterfly hot loop |
| `Array::mapi_in_place` | In-place Hann window application |
| `Array::makei` | Functional array construction for FFT input and magnitude extraction |
| `Array::fold` | Functional RMS calculation |
| `StringBuilder` | Efficient string building for terminal output |
| `Double::clamp` / `Int32::clamp` | Safe value clamping with labeled arguments |
| `match` patterns | Chunk type dispatch, arg parsing, bar render states |
| `guard` patterns | Early return on file not found / parse failure |
| `test` blocks | 21 inline tests for FFT correctness, WAV parsing, arg parsing |
| `enum` + `match` | `ChunkType` enum for WAV chunk identification |
| Bit tricks | `n & (n-1)` for power-of-2 check |

## Testing

```bash
# Run all 21 inline tests
moon test --target native

# Type check with no warnings
moon check --target native --deny-warn

# Format check
moon fmt && git diff --exit-code
```

## CI

GitHub Actions CI runs on every push and pull request:

1. **Check & Format** — `moon check --deny-warn` + `moon fmt` diff check
2. **Build & Test** — `moon build` + `moon test` (21 inline tests)
3. **Integration** — Generate WAV files, run visualizer, verify output, test
   multiple FFT sizes, verify error handling

Matrix: Ubuntu + macOS (native target only).

## Project Structure

```
moonFFTmusic/
├── .github/workflows/ci.yml   # GitHub Actions CI
├── src/main/
│   ├── moon.pkg               # Package imports
│   ├── fft.mbt               # FFT engine + Complex struct + tests
│   ├── wav.mbt               # WAV parser + tests
│   ├── display.mbt           # ANSI spectrum renderer (16 visual effects)
│   └── main.mbt              # Entry point + arg parsing + tests
├── gen_wav.py                 # WAV file generator
├── run.sh                     # Build & run script
├── moon.mod                   # Module definition
└── README.md
```

## License

MIT
