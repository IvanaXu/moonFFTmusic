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
      println("🎵 moonFFTmusic — Real-time Spectrum Analyzer")
      println("")
      println("Usage: moonFFTmusic <wav_file> [fft_size]")
      println("  wav_file:  path to WAV file (16-bit PCM)")
      println("  fft_size:  FFT window size, power of 2 (default: 1024)")
      println("")
      println("Environment:")
      println("  LINES:     terminal height for auto-layout (default: 26)")
      println("")
      println("Visual effects: rainbow flow, beat flash, beat bloom,")
      println("  bar crown, scanline, dominant spotlight, progress pulse,")
      println("  RMS glow, spectrogram waterfall, piano keyboard,")
      println("  BPM estimation, frequency band meters, auto-gain")
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
  // Auto-detect terminal height to prevent scroll flicker.
  // Fixed overhead per frame: 4(header) + 1(peak) + 1(trail) + 3(glow)
  //   + 1(labels) + 1(waveform) + 1(sparkline) + 1(RMS) + 1(progress) = 14
  // max_height = terminal_lines - 14, clamped to [8, 40]
  let max_height = match @env.get_env_var("LINES") {
    Some(s) => {
      // Parse LINES env var to int
      let mut lines = 0
      let mut valid = false
      for c in s {
        if c >= '0' && c <= '9' {
          lines = lines * 10 + (c.to_int() - '0'.to_int())
          valid = true
        }
      }
      if valid {
        (lines - 14).clamp(min=8, max=40)
      } else {
        12
      }
    }
    None => 12 // default: fits 26-line terminal
  }
  let sub_res = 8
  let sleep_ms : Int32 = 50
  let hop_size = fft_size / 2

  // --- Precompute all FFT tables ONCE at startup ---
  let (tw_re, tw_im) = precompute_twiddles_soa(fft_size)
  let hann = precompute_hann_window(fft_size)
  let bits = log2_int(fft_size)
  let bit_rev = precompute_bit_reversal(fft_size, bits)

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
  let render_prev = Array::make(num_bars, 0.0) // double IIR state for anti-flicker

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
  // Precompute total time string (invariant across frames)
  let total_time_str = format_time(total, wav.sample_rate)
  let mut pos = 0
  let mut frame_count = 0
  // Sticky dominant bar — resists jitter when multiple bars have similar magnitude.
  // Only switch when the new bar is >20% stronger or >3 positions away.
  let mut last_dom_bar = 0
  while pos + fft_size <= total {
    // Step 1-3 FUSED: Load samples + compute RMS + apply Hann window in one pass
    // (eliminates 2 separate loops over fft_size = 2048 iterations saved per frame)
    let mut sum_sq = 0.0
    for i in 0..<fft_size {
      let s = wav.samples.unsafe_get(pos + i)
      sum_sq += s * s
      re.unsafe_set(i, s * hann.unsafe_get(i))
      im.unsafe_set(i, 0.0)
    }
    let rms = (sum_sq / fft_size.to_double()).sqrt()

    // Step 4: Compute SoA FFT (in-place, zero allocations)
    fft_soa(re, im, tw_re, tw_im, bit_rev)

    // Step 5: Compute mag² for ALL bins (NO sqrt — just re²+im²)
    for i in 0..<half {
      let r = re.unsafe_get(i)
      let imv = im.unsafe_get(i)
      mag_sq.unsafe_set(i, r * r + imv * imv)
    }

    // Step 6: Bin aggregation — for each bar, find max mag² in bin range,
    // then sqrt only once per bar (60 sqrts vs 512)
    let bin_starts = ctx.bin_starts
    let bin_ends = ctx.bin_ends
    for bar in 0..<num_bars {
      let start = bin_starts.unsafe_get(bar)
      let end = bin_ends.unsafe_get(bar)
      let mut max_sq = 0.0
      for bin_idx in start..<end {
        let sq = mag_sq.unsafe_get(bin_idx)
        if sq > max_sq {
          max_sq = sq
        }
      }
      magnitudes.unsafe_set(bar, max_sq.sqrt())
    }

    // Step 7: Update beat detector + energy sparkline + peak trail
    // Current time in seconds for BPM estimation
    let current_time = pos.to_double() / wav.sample_rate.to_double()
    let beat_intensity = beat_detector.update(rms, current_time)

    // Step 8: Fill waveform array in-place (no allocation)
    let wav_samples = wav.samples
    for i in 0..<num_bars {
      let idx = pos + i * fft_size / num_bars
      waveform.unsafe_set(
        i,
        if idx < total {
          wav_samples.unsafe_get(idx)
        } else {
          0.0
        },
      )
    }

    // Step 9: Render and display (all arrays reused, zero alloc)
    // Find dominant bar with sticky logic to prevent trail flicker.
    // The dominant bar only switches if the new peak is >20% stronger
    // or >3 positions away from the last — this prevents the ● dot
    // from jumping between adjacent bars with similar magnitudes.
    let mut raw_dom_bar = 0
    let mut dom_max = 0.0
    for bar in 0..<num_bars {
      let m = magnitudes.unsafe_get(bar)
      if m > dom_max {
        dom_max = m
        raw_dom_bar = bar
      }
    }
    let dom_bar = if (raw_dom_bar - last_dom_bar).abs() > 3 ||
      dom_max > magnitudes.unsafe_get(last_dom_bar) * 1.2 {
      last_dom_bar = raw_dom_bar
      raw_dom_bar
    } else {
      last_dom_bar
    }
    // Rainbow hue rotation: swap to precomputed color table (zero alloc)
    ctx.color_table_idx = frame_count % 40
    let display = render_spectrum(
      magnitudes,
      ctx,
      peak_heights,
      peak_frames,
      prev_heights,
      render_prev,
      heights,
      pos,
      total,
      rms,
      beat_intensity,
      waveform,
      total_time_str,
      dom_bar,
      beat_detector.bpm,
      beat_detector.beat_pulse,
    )
    println(display)

    // Step 10: Sleep to control refresh rate
    @async.sleep(sleep_ms)

    // Step 11: Advance with overlap
    pos += hop_size
    frame_count += 1
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
