// =============================================================================
// Main Program — Audio spectrum visualizer entry point
// Optimized with MoonBit features: Array::fold, Array::mapi, match patterns,
// guard expressions, Complex struct methods
// =============================================================================

///|
/// Check if a number is a power of 2 and >= minimum
/// Uses bit trick: power of 2 has exactly one bit set, so (n & (n-1)) == 0
fn is_power_of_two(n : Int32) -> Bool {
  n > 0 && (n & (n - 1)) == 0
}

///|
/// Parse FFT size from argument string, defaulting to 1024
/// Uses match pattern for clean argument handling
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
///   wav_file:  path to a 16-bit PCM WAV file
///   fft_size:  FFT window size, must be power of 2 (default: 1024)
async fn main {
  // --- Parse command line arguments using match pattern ---
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

  // --- Validate FFT size using bit trick ---
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
  let max_height = 22
  let sleep_ms : Int32 = 50
  let hop_size = fft_size / 2

  // --- Initialize peak hold arrays ---
  let peak_heights = Array::make(num_bars, 0)
  let peak_frames = Array::make(num_bars, 0)

  // --- Initialize temporal smoothing state ---
  let prev_heights = Array::make(num_bars, 0)

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
    // Step 1: Build chunk using Array::mapi (functional construction)
    let chunk = Array::makei(fft_size, fn(i) {
      if pos + i < total {
        Complex::{ re: wav.samples[pos + i], im: 0.0, }
      } else {
        Complex::{ re: 0.0, im: 0.0, }
      }
    })

    // Step 2: Calculate RMS using Array::fold (functional style)
    // RMS = sqrt(sum(sample²) / N)
    let sum_sq = chunk.fold(init=0.0, fn(acc, z) { acc + z.re * z.re })
    let rms = (sum_sq / fft_size.to_double()).sqrt()

    // Step 3: Apply Hann window (uses mapi_in_place internally)
    apply_hann_window(chunk)

    // Step 4: Compute FFT (in-place)
    fft(chunk)

    // Step 5: Extract magnitudes using Array::mapi (functional style)
    let magnitudes = Array::makei(half, fn(i) { chunk[i].mag() })

    // Step 6: Render and display
    let display = render_spectrum(
      magnitudes,
      num_bars,
      max_height,
      wav.sample_rate,
      fft_size,
      peak_heights,
      peak_frames,
      prev_heights,
      pos,
      total,
      rms,
    )
    println(display)

    // Step 7: Sleep to control refresh rate
    @async.sleep(sleep_ms)

    // Step 8: Advance with overlap
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
