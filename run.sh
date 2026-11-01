#!/bin/bash
# run.sh — Build and run moonFFTmusic with a test WAV file
# Usage: ./run.sh [wav_file] [fft_size]

set -e

# Ensure moon is in PATH (check both sandbox and host locations)
export PATH="/root/.moon/bin:/workspace/.moon/bin:$PATH"

# Default arguments
WAV_FILE="${1:-test.wav}"
FFT_SIZE="${2:-1024}"

# Generate test WAV file if it doesn't exist
if [ ! -f "$WAV_FILE" ]; then
    echo "Generating test WAV file: $WAV_FILE"
    python3 gen_wav.py "$WAV_FILE" 440.0
fi

# Build the project (release for best performance)
echo "Building moonFFTmusic (release)..."
moon build --target native --release

# Run the visualizer
echo "Starting spectrum visualizer..."
echo "Press Ctrl+C to stop."
echo ""
./_build/native/release/build/src/main/main.exe "$WAV_FILE" "$FFT_SIZE"
