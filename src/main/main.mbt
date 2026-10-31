// =============================================================================
// Main Program — Audio spectrum visualizer entry point
// Reads WAV file, performs FFT on chunks, displays real-time spectrum
// =============================================================================

///|
/// Entry point: parse arguments, read WAV file, run visualization loop
///
/// Usage: moonFFTmusic <wav_file> [fft_size]
///   wav_file:  path to a 16-bit PCM WAV file
///   fft_size:  FFT window size, must be power of 2 (default: 1024)
async fn main {
  // --- Parse command line arguments ---
  let args = @env.args()
  if args.length() < 2 {
    println("Usage: moonFFTmusic <wav_file> [fft_size]")
    println("  wav_file:  path to WAV file (16-bit PCM)")
    println("  fft_size:  FFT window size, power of 2 (default: 1024)")
    return
  }
  let wav_path = args[1]
  let fft_size : Int32 = if args.length() >= 3 {
    @string.parse_int(args[2]) catch {
      _ => 1024
    }
  } else {
    1024
  }

  // --- Validate FFT size is a power of 2 and >= 256 ---
  let mut n = fft_size
  let mut is_pow2 = true
  while n > 1 {
    if n % 2 != 0 {
      is_pow2 = false
      break
    }
    n = n / 2
  }
  if !is_pow2 || fft_size < 256 {
    println("Error: FFT size must be a power of 2 and at least 256")
    println("Valid sizes: 256, 512, 1024, 2048, 4096, ...")
    return
  }

  // --- Check if WAV file exists ---
  if !@fs.exists(wav_path) {
    println("Error: File not found: \{wav_path}")
    return
  }

  // --- Read and parse WAV file ---
  let data = @fs.read_binary(wav_path)
  guard read_wav(data) is Some(wav) else {
    println("Error: Failed to parse WAV file")
    println("Requires valid RIFF/WAVE format with 16-bit PCM audio")
    return
  }

  if wav.samples.length() == 0 {
    println("Error: No audio samples found in WAV file")
    return
  }

  // --- Display configuration ---
  let num_bars = 60 // number of frequency bars to display
  let max_height = 22 // maximum bar height in terminal rows
  let sleep_ms : Int32 = 50 // refresh interval in milliseconds
  let hop_size = fft_size / 2 // 50% overlap between chunks

  // --- Initialize peak hold arrays ---
  let peak_heights = Array::make(num_bars, 0)
  let peak_frames = Array::make(num_bars, 0)

  // --- Print initial info ---
  println("Loading WAV file: \{wav_path}")
  println(
    "Sample rate: \{wav.sample_rate}Hz, Channels: \{wav.num_channels}, Bits: \{wav.bits_per_sample}",
  )
  println("Total samples: \{wav.samples.length()}, FFT size: \{fft_size}")
  @async.sleep(500) // brief pause before starting

  // --- Main visualization loop ---
  let total = wav.samples.length()
  let mut pos = 0
  while pos + fft_size <= total {
    // Step 1: Read a chunk of audio samples into complex array
    let chunk = Array::make(fft_size, Complex::{ re: 0.0, im: 0.0, })
    for i in 0..<fft_size {
      if pos + i < total {
        chunk[i] = Complex::{ re: wav.samples[pos + i], im: 0.0, }
      }
    }

    // Step 2: Calculate RMS of current chunk (for volume meter)
    let mut sum_sq = 0.0
    for i in 0..<fft_size {
      let s = chunk[i].re
      sum_sq = sum_sq + s * s
    }
    let rms = (sum_sq / fft_size.to_double()).sqrt()

    // Step 3: Apply Hann window to reduce spectral leakage
    apply_hann_window(chunk)

    // Step 4: Compute FFT (in-place transform)
    fft(chunk)

    // Step 5: Calculate magnitudes for first half (real frequencies)
    let half = fft_size / 2
    let magnitudes = Array::make(half, 0.0)
    for i in 0..<half {
      magnitudes[i] = chunk[i].mag()
    }

    // Step 6: Render spectrum bar chart to terminal
    let display = render_spectrum(
      magnitudes,
      num_bars,
      max_height,
      wav.sample_rate,
      fft_size,
      peak_heights,
      peak_frames,
      pos,
      total,
      rms,
    )
    println(display)

    // Step 7: Sleep to control refresh rate
    @async.sleep(sleep_ms)

    // Step 8: Advance to next chunk (with overlap)
    pos += hop_size
  }

  // --- Playback complete ---
  println("\u001b[0m\u001b[2J\u001b[H")
  println("Playback complete.")
  println("Total samples processed: \{total}")
  println("Sample rate: \{wav.sample_rate}Hz")
}
