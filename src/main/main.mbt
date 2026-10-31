// =============================================================================
// Main Program — Audio spectrum visualizer entry point
//
// Optimized with MoonBit features:
//   - SoA FFT: separate re/im Array[Double], zero allocations in hot loop
//   - Precomputed twiddle table: single table reused across all FFT calls
//   - Precomputed Hann window: coefficients computed once at startup
//   - Precomputed DisplayContext: bin mapping, grid positions, colors
//   - BeatDetector: energy history for rhythmic pulse detection
//   - Array::fold for RMS, match patterns for arg parsing
// =============================================================================

///|
/// Check if a number is a power of 2 and >= minimum
/// Uses bit trick: power of 2 has exactly one bit set, so (n & (n-1)) == 0
fn is_power_of_two(n : Int32) -> Bool {
  n > 0 && (n & (n - 1)) == 0
}

///|
/// Parse FFT size from argument string, defaulting to 1024
fn parse_fft_size(arg : String?) -> Int32 {
  match arg {
    Some(s) => @string.parse_int(s) catch { _ => 1024 }
    None => 1024
  }
}

///|
/// Entry point: parse arguments, read WAV file, run visualization loop
///
/// Usage: moonFFTmusic <wav_file> [fft_size]
async fn main {
  // --- Parse command line arguments ---
  let args = @env.args()
  match args.length() {
    n if n < 2 => {
      println("Usage: moonFFTmusic <wav_file> [fft_size]")
      println("  wav_file:  path to WAV file (16-bit PCM)")
      println("  fft_size:  FFT window size, power of 2 (default: 1024)")
      return
    }
    _ => ()
  }
  let wav_path = args[1]
  let fft_size = parse_fft_size(
    if args.length() >= 3 {
      Some(args[2])
    } else {
      None
    },
  )

  // --- Validate FFT size ---
  if !is_power_of_two(fft_size) || fft_size < 256 {
    println("Error: FFT size must be a power of 2 and at least 256")
    println("Valid sizes: 256, 512, 1024, 2048, 4096, ...")
    return
  }

  // --- Check if WAV file exists ---
  guard @fs.exists(wav_path) else {
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

  guard wav.samples.length() > 0 else {
    println("Error: No audio samples found in WAV file")
    return
  }

  // --- Display configuration ---
  let num_bars = 60
  let max_height = 26
  let sub_res = 8
  let sleep_ms : Int32 = 50
  let hop_size = fft_size / 2

  // --- Precompute all FFT tables ONCE at startup ---
  // Twiddle factors: single table of size N/2, reused via striding
  let (tw_re, tw_im) = precompute_twiddles_soa(fft_size)
  // Hann window coefficients
  let hann = precompute_hann_window(fft_size)
  // log2(fft_size) for bit-reversal
  let bits = log2_int(fft_size)

  // --- Precompute display context ONCE at startup ---
  let ctx = create_display_context(
    num_bars,
    max_height,
    sub_res,
    fft_size / 2,
    wav.sample_rate,
    fft_size,
  )

  // --- Initialize beat detector (43 frames ~ 1 second at 50ms refresh) ---
  let beat_detector = BeatDetector::new(43)

  // --- Initialize peak hold arrays ---
  let peak_heights = Array::make(num_bars, 0)
  let peak_frames = Array::make(num_bars, 0)

  // --- Initialize temporal smoothing state ---
  let prev_heights = Array::make(num_bars, 0)

  // --- Pre-allocate re/im arrays for FFT (reused every frame, zero alloc) ---
  let re = Array::make(fft_size, 0.0)
  let im = Array::make(fft_size, 0.0)

  // --- Print initial info ---
  println("Loading WAV file: \{wav_path}")
  println(
    "Sample rate: \{wav.sample_rate}Hz, Channels: \{wav.num_channels}, Bits: \{wav.bits_per_sample}",
  )
  println("Total samples: \{wav.samples.length()}, FFT size: \{fft_size}")
  @async.sleep(500)

  // --- Main visualization loop ---
  let total = wav.samples.length()
  let half = fft_size / 2
  let mut pos = 0
  while pos + fft_size <= total {
    // Step 1: Fill re/im arrays directly from WAV samples (zero Complex alloc)
    // im[] is already all zeros from initialization, just need to ensure it
    for i in 0..<fft_size {
      re[i] = wav.samples[pos + i]
      im[i] = 0.0
    }

    // Step 2: Calculate RMS directly from re[] (before windowing)
    let mut sum_sq = 0.0
    for i in 0..<fft_size {
      let s = re.unsafe_get(i)
      sum_sq += s * s
    }
    let rms = (sum_sq / fft_size.to_double()).sqrt()

    // Step 3: Apply Hann window (in-place on re[], im[] stays zero)
    apply_hann_window_soa(re, hann)

    // Step 4: Compute SoA FFT (in-place, zero allocations)
    fft_soa(re, im, tw_re, tw_im, bits)

    // Step 5: Extract magnitudes (sqrt only for displayed bins)
    let magnitudes = Array::makei(half, fn(i) {
      let r = re.unsafe_get(i)
      let imv = im.unsafe_get(i)
      (r * r + imv * imv).sqrt()
    })

    // Step 6: Update beat detector
    let beat_intensity = beat_detector.update(rms)

    // Step 7: Build waveform display data (downsampled chunk)
    let waveform = Array::makei(num_bars, fn(i) {
      let idx = pos + i * fft_size / num_bars
      if idx < total {
        wav.samples[idx]
      } else {
        0.0
      }
    })

    // Step 8: Render and display
    let display = render_spectrum(
      magnitudes, ctx, peak_heights, peak_frames, prev_heights, pos, total, rms,
      beat_intensity, waveform,
    )
    println(display)

    // Step 9: Sleep to control refresh rate
    @async.sleep(sleep_ms)

    // Step 10: Advance with overlap
    pos += hop_size
  }

  // --- Playback complete ---
  println("\u001b[0m\u001b[2J\u001b[H")
  println("Playback complete.")
  println("Total samples processed: \{total}")
  println("Sample rate: \{wav.sample_rate}Hz")
}

// =============================================================================
// Inline Tests
// =============================================================================

///|
test "is_power_of_two detects powers of 2" {
  assert_true(is_power_of_two(1))
  assert_true(is_power_of_two(2))
  assert_true(is_power_of_two(256))
  assert_true(is_power_of_two(1024))
  assert_true(is_power_of_two(4096))
}

///|
test "is_power_of_two rejects non-powers of 2" {
  assert_false(is_power_of_two(0))
  assert_false(is_power_of_two(3))
  assert_false(is_power_of_two(1000))
  assert_false(is_power_of_two(1023))
  assert_false(is_power_of_two(-4))
}

///|
test "parse_fft_size defaults to 1024" {
  assert_eq(parse_fft_size(None), 1024)
}

///|
test "parse_fft_size parses valid input" {
  assert_eq(parse_fft_size(Some("2048")), 2048)
  assert_eq(parse_fft_size(Some("512")), 512)
}

///|
test "parse_fft_size falls back on invalid input" {
  assert_eq(parse_fft_size(Some("abc")), 1024)
}
