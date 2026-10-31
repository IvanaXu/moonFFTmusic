# moonFFTmusic

[![CI](https://github.com/IvanaXu/moonFFTmusic/actions/workflows/ci.yml/badge.svg)](https://github.com/IvanaXu/moonFFTmusic/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A real-time audio spectrum visualizer written in [MoonBit](https://www.moonbitlang.com/).
It reads a WAV file, performs Fast Fourier Transform (FFT) on audio chunks, and
displays a live frequency spectrum as a beautiful ANSI bar chart in the terminal.

## Features

- **WAV File Reader**: Parses RIFF/WAVE headers and reads 16-bit signed PCM audio
  (mono and stereo). Samples are normalized to [-1.0, 1.0].
- **FFT Engine**: Iterative radix-2 Cooley-Tukey FFT with precomputed twiddle
  factors and in-place butterfly operations. Uses `unsafe_get`/`unsafe_set` for
  hot-loop performance.
- **Hann Window**: Applied before FFT to reduce spectral leakage, using
  `Array::mapi_in_place` for efficient in-place computation.
- **ANSI Spectrum Display**: 60-bar frequency spectrum with:
  - 26-color rainbow gradient (blue → green → yellow → red)
  - Partial block characters (▁▂▃▄▅▆▇█) for sub-row resolution
  - Peak hold with gravity decay
  - Log-spaced frequency labels (50Hz – 10kHz)
  - RMS level meter with dB readout
  - Progress bar with time display
  - Box-drawing header with real-time peak frequency

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

## Quick Start

```bash
# Install MoonBit CLI (Unix)
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

# Build
moon build --target native

# Generate a test WAV file (440Hz sine wave, 2 seconds)
python3 gen_wav.py test.wav 440.0

# Run the visualizer
moon run src/main test.wav 1024
```

Or use the included script:

```bash
./run.sh [wav_file] [fft_size]
```

## Usage

```
moonFFTmusic <wav_file> [fft_size]

Arguments:
  wav_file   Path to a 16-bit PCM WAV file
  fft_size   FFT window size, must be power of 2 (default: 1024)
             Valid: 256, 512, 1024, 2048, 4096, ...
```

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
│   ├── display.mbt           # ANSI spectrum renderer
│   └── main.mbt              # Entry point + arg parsing + tests
├── gen_wav.py                 # WAV file generator
├── run.sh                     # Build & run script
├── moon.mod                   # Module definition
└── README.md
```

## License

MIT
