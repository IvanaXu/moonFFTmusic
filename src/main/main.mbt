// =============================================================================
// Main Program — Audio spectrum visualizer entry point
//
// Second-round optimizations:
//   - Pre-allocated mag_sq[], magnitudes[], heights[], waveform[] arrays
//     (zero per-frame array allocations)
//   - mag² computation (no sqrt) for all bins, sqrt only for 60 displayed bars
//   - Bin aggregation: max mag² across bin range per bar
//   - Reusable arrays passed to render_spectrum
//
// First-round optimizations (already in place):
//   - SoA FFT with precomputed twiddle table
//   - Precomputed Hann window
//   - Precomputed DisplayContext (bin mapping, grid, colors, color_table)
//   - BeatDetector with rolling sum
// =============================================================================

///|
fn is_power_of_two(n : Int32) -> Bool {
  n > 0 && (n & (n - 1)) == 0
}

///|
fn parse_fft_size(arg : String?) -> Int32 {
  match arg {
    Some(s) => @string.parse_int(s) catch { _ => 1024 }
    None => 1024
  }
}

///|
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
  let (tw_re, tw_im) = precompute_twiddles_soa(fft_size)
  let hann = precompute_hann_window(fft_size)
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

  // --- Initialize beat detector ---
  let beat_detector = BeatDetector::new(43)

  // --- Initialize peak hold arrays ---
  let peak_heights = Array::make(num_bars, 0)
  let peak_frames = Array::make(num_bars, 0)

  // --- Initialize temporal smoothing state ---
  let prev_heights = Array::make(num_bars, 0)

  // --- Pre-allocate ALL per-frame arrays (reused every frame, zero alloc) ---
  let re = Array::make(fft_size, 0.0) // FFT real input/output
  let im = Array::make(fft_size, 0.0) // FFT imaginary input/output
  let half = fft_size / 2
  let mag_sq = Array::make(half, 0.0) // mag² for all bins (no sqrt)
  let magnitudes = Array::make(num_bars, 0.0) // aggregated magnitudes per bar
  let heights = Array::make(num_bars, 0) // bar heights (reusable)
  let waveform = Array::make(num_bars, 0.0) // waveform display data

  // --- Print initial info ---
  println("Loading WAV file: \{wav_path}")
  println(
    "Sample rate: \{wav.sample_rate}Hz, Channels: \{wav.num_channels}, Bits: \{wav.bits_per_sample}",
  )
  println("Total samples: \{wav.samples.length()}, FFT size: \{fft_size}")
  @async.sleep(500)

  // --- Main visualization loop ---
  let total = wav.samples.length()
  let mut pos = 0
  while pos + fft_size <= total {
    // Step 1: Fill re/im arrays directly from WAV samples (zero Complex alloc)
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

    // Step 5: Compute mag² for ALL bins (NO sqrt — just re²+im²)
    for i in 0..<half {
      let r = re.unsafe_get(i)
      let imv = im.unsafe_get(i)
      mag_sq.unsafe_set(i, r * r + imv * imv)
    }

    // Step 6: Bin aggregation — for each bar, find max mag² in bin range,
    // then sqrt only once per bar (60 sqrts vs 512)
    for bar in 0..<num_bars {
      let start = ctx.bin_starts[bar]
      let end = ctx.bin_ends[bar]
      let mut max_sq = 0.0
      for bin_idx in start..<end {
        let sq = mag_sq.unsafe_get(bin_idx)
        if sq > max_sq {
          max_sq = sq
        }
      }
      magnitudes.unsafe_set(bar, max_sq.sqrt())
    }

    // Step 7: Update beat detector
    let beat_intensity = beat_detector.update(rms)

    // Step 8: Fill waveform array in-place (no allocation)
    for i in 0..<num_bars {
      let idx = pos + i * fft_size / num_bars
      waveform[i] = if idx < total { wav.samples[idx] } else { 0.0 }
    }

    // Step 9: Render and display (all arrays reused, zero alloc)
    let display = render_spectrum(
      magnitudes, ctx, peak_heights, peak_frames, prev_heights, heights, pos, total,
      rms, beat_intensity, waveform,
    )
    println(display)

    // Step 10: Sleep to control refresh rate
    @async.sleep(sleep_ms)

    // Step 11: Advance with overlap
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
