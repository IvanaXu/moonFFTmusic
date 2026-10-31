// =============================================================================
// Terminal Display Module — Beautiful ANSI spectrum visualizer
// Features: rainbow gradient, peak hold, partial blocks, log-spaced freq,
//           progress bar, frequency labels, box-drawing header, RMS meter
// =============================================================================

///|
/// 256-color rainbow palette for frequency bars (blue → cyan → green → yellow → orange → red → magenta)
let rainbow_palette : Array[Int32] = [
  21, 27, 33, 39, 45, 51, 50, 49, 48, 47, 46, 82, 118, 154, 190, 226, 215, 214,
  213, 208, 203, 204, 198, 199, 200, 201,
]

///|
/// Partial block characters for 8x vertical resolution
let partial_blocks : Array[String] = [
  " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
]

///|
/// Clear screen and move cursor to home position
fn clear_screen() -> String {
  "\u001b[2J\u001b[H"
}

///|
/// Get 256-color ANSI code for a frequency bar using rainbow gradient
fn gradient_color(bar : Int32, num_bars : Int32) -> String {
  let idx = bar * (rainbow_palette.length() - 1) / num_bars
  let color = if idx < 0 {
    21
  } else if idx >= rainbow_palette.length() {
    201
  } else {
    rainbow_palette[idx]
  }
  "\u001b[38;5;\{color}m"
}

///|
/// Get a dimmer version of the rainbow color (for peak markers)
fn gradient_color_dim(bar : Int32, num_bars : Int32) -> String {
  let idx = bar * (rainbow_palette.length() - 1) / num_bars
  let color = if idx < 0 {
    21
  } else if idx >= rainbow_palette.length() {
    201
  } else {
    rainbow_palette[idx]
  }
  // Use a dimmer color by reducing the color code
  let dim_color = if color >= 16 && color <= 231 {
    // 6x6x6 color cube: reduce each component
    let r = (color - 16) / 36
    let g = ((color - 16) % 36) / 6
    let b = (color - 16) % 6
    let dr = if r > 0 { r - 1 } else { 0 }
    let dg = if g > 0 { g - 1 } else { 0 }
    let db = if b > 0 { b - 1 } else { 0 }
    16 + dr * 36 + dg * 6 + db
  } else {
    color
  }
  "\u001b[38;5;\{dim_color}m"
}

///|
/// Map a bar index to FFT bin using logarithmic spacing
/// This gives more visual resolution for low (bass) frequencies
fn log_freq_bin(bar : Int32, num_bars : Int32, half_fft : Int32) -> Int32 {
  if half_fft <= 1 {
    return 0
  }
  let ratio = bar.to_double() / num_bars.to_double()
  let log_val = @math.pow(2.0, ratio * @math.log2(half_fft.to_double()))
  let bin = log_val.to_int() - 1
  if bin < 0 {
    0
  } else if bin >= half_fft {
    half_fft - 1
  } else {
    bin
  }
}

///|
/// Inverse log mapping: given a frequency in Hz, find which bar it corresponds to
fn freq_to_bar(freq : Double, num_bars : Int32, half_fft : Int32, sample_rate : Int32) -> Int32 {
  if freq <= 0.0 || half_fft <= 1 {
    return 0
  }
  let bin = freq * fft_size_from_half(half_fft).to_double() / sample_rate.to_double()
  if bin <= 0.0 {
    return 0
  }
  let ratio = @math.log2(bin) / @math.log2(half_fft.to_double())
  let bar = (ratio * num_bars.to_double()).to_int()
  if bar < 0 {
    0
  } else if bar >= num_bars {
    num_bars - 1
  } else {
    bar
  }
}

///|
/// Reconstruct fft_size from half_fft
fn fft_size_from_half(half_fft : Int32) -> Int32 {
  half_fft * 2
}

///|
/// Format time in seconds as MM:SS.s
fn format_time(samples : Int32, sample_rate : Int32) -> String {
  let total_ms = samples * 1000 / sample_rate
  let minutes = total_ms / 60000
  let seconds = (total_ms % 60000) / 1000
  let tenths = (total_ms % 1000) / 100
  "\{minutes}:\{seconds}.\{tenths}"
}

///|
/// Format frequency nicely (Hz or kHz)
fn format_freq(hz : Int32) -> String {
  if hz >= 1000 {
    "\{hz / 1000}kHz"
  } else {
    "\{hz}Hz"
  }
}

///|
/// Render the frequency spectrum with all visual enhancements
///
/// # Parameters
/// - magnitudes: FFT magnitude for each frequency bin
/// - num_bars: number of vertical bars (typically 50-60)
/// - max_height: maximum bar height in terminal rows
/// - sample_rate: audio sample rate
/// - fft_size: FFT window size
/// - peak_heights: tracked peak heights per bar (mutable, updated in place)
/// - peak_frames: how many frames each peak has held (mutable)
/// - current_pos: current playback position in samples
/// - total_samples: total audio samples
/// - rms_value: RMS of current chunk (for volume meter)
fn render_spectrum(
  magnitudes : Array[Double],
  num_bars : Int32,
  max_height : Int32,
  sample_rate : Int32,
  fft_size : Int32,
  peak_heights : Array[Int32],
  peak_frames : Array[Int32],
  current_pos : Int32,
  total_samples : Int32,
  rms_value : Double,
) -> String {
  let mut output = clear_screen()
  let half_fft = fft_size / 2
  let sub_resolution = 8 // partial block levels per row
  let max_levels = max_height * sub_resolution

  // --- Calculate bar heights using log-spaced freq mapping ---
  let heights = Array::make(num_bars, 0)
  let mut dominant_bin = 0
  let mut max_mag = 0.0
  for bar in 0..<num_bars {
    let bin_idx = log_freq_bin(bar, num_bars, half_fft)
    if bin_idx < magnitudes.length() {
      let mag = magnitudes[bin_idx]
      if mag > max_mag {
        max_mag = mag
        dominant_bin = bin_idx
      }
      // Logarithmic magnitude scaling
      let log_mag = if mag > 0.0 {
        @math.log10(mag * 1000.0 + 1.0) / 3.0
      } else {
        0.0
      }
      let clamped = if log_mag > 1.0 {
        1.0
      } else if log_mag < 0.0 {
        0.0
      } else {
        log_mag
      }
      heights[bar] = (clamped * max_levels.to_double()).to_int()
    }
  }

  // --- Update peak hold with gravity decay ---
  for bar in 0..<num_bars {
    if heights[bar] >= peak_heights[bar] {
      peak_heights[bar] = heights[bar]
      peak_frames[bar] = 0
    } else {
      peak_frames[bar] = peak_frames[bar] + 1
      if peak_frames[bar] > 3 {
        if peak_heights[bar] > 0 {
          peak_heights[bar] = peak_heights[bar] - sub_resolution / 2
        }
        peak_frames[bar] = 0
      }
    }
  }

  // --- Dominant frequency ---
  let dominant_freq = dominant_bin * sample_rate / fft_size

  // --- Box-drawing header ---
  let header_width = num_bars + 2
  let mut top_border = "╔"
  for _ in 0..<header_width {
    top_border += "═"
  }
  top_border += "╗\n"

  let mut bottom_border = "╚"
  for _ in 0..<header_width {
    bottom_border += "═"
  }
  bottom_border += "╝\n"

  let title = "🎵 MoonFFTmusic — Real-time Spectrum Analyzer"
  let info_line = "Rate: \{sample_rate}Hz | FFT: \{fft_size} | Bars: \{num_bars} | Peak: \{format_freq(dominant_freq)} | Time: \{format_time(current_pos, sample_rate)}"

  // Pad lines to fit the box
  let mut title_padded = title
  let title_pad = header_width - title.length() - 2
  if title_pad > 0 {
    for _ in 0..<title_pad {
      title_padded += " "
    }
  }

  let mut info_padded = info_line
  let info_pad = header_width - info_line.length() - 2
  if info_pad > 0 {
    for _ in 0..<info_pad {
      info_padded += " "
    }
  }

  output += "\u001b[1;36m" + top_border
  output += "║ " + title_padded + " ║\n"
  output += "║ " + info_padded + " ║\n"
  output += bottom_border + "\u001b[0m\n"

  // --- Render bars from top to bottom with partial blocks ---
  for row in 0..<max_height {
    let level_top = (max_height - row) * sub_resolution
    let level_bottom = (max_height - row - 1) * sub_resolution
    let mut line = ""
    for bar in 0..<num_bars {
      let h = heights[bar]
      let ph = peak_heights[bar]

      if h >= level_top {
        // Full block at this level
        line += gradient_color(bar, num_bars) + "█"
      } else if h > level_bottom {
        // Partial block: compute which partial character to use
        let frac = h - level_bottom
        let block_idx = if frac >= sub_resolution {
          sub_resolution
        } else {
          frac
        }
        line += gradient_color(bar, num_bars) + partial_blocks[block_idx]
      } else if ph >= level_top && ph > 0 {
        // Peak marker (dim)
        line += gradient_color_dim(bar, num_bars) + "▔"
      } else {
        line += " "
      }
    }
    output += line + "\u001b[0m\n"
  }

  // --- Frequency axis labels ---
  output += "\u001b[90m"
  let freq_labels : Array[Int32] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
  // Build a label line
  let mut label_line = ""
  let mut label_pos = 0
  for i in 0..<num_bars {
    // Check if any frequency label maps to this bar position
    let mut found_label = ""
    for j in 0..<freq_labels.length() {
      let target_bar = freq_to_bar(
        freq_labels[j].to_double(),
        num_bars,
        half_fft,
        sample_rate,
      )
      if target_bar == i {
        let label = format_freq(freq_labels[j])
        found_label = label
        break
      }
    }
    if found_label.length() > 0 {
      // Place label, advance position
      while label_pos < i {
        label_line += " "
        label_pos = label_pos + 1
      }
      label_line += found_label
      label_pos = i + found_label.length()
    }
  }
  output += label_line + "\n"
  output += "\u001b[0m"

  // --- RMS volume meter ---
  let rms_db = if rms_value > 0.0 {
    20.0 * @math.log10(rms_value)
  } else {
    -99.0
  }
  let rms_pct = if rms_value > 0.0 {
    let db_norm = (rms_db + 60.0) / 60.0
    if db_norm > 1.0 {
      1.0
    } else if db_norm < 0.0 {
      0.0
    } else {
      db_norm
    }
  } else {
    0.0
  }
  let meter_width = 20
  let meter_filled = (rms_pct * meter_width.to_double()).to_int()
  output += "\n\u001b[1;37mRMS: \u001b[0m"
  output += "\u001b[32m["
  for i in 0..<meter_width {
    if i < meter_filled {
      output += "█"
    } else {
      output += "░"
    }
  }
  output += "]\u001b[0m "
  // Format dB with 1 decimal place
  let db_int = rms_db.to_int()
  let db_frac = ((rms_db - db_int.to_double()) * 10.0).abs().to_int()
  output += "\{db_int}.\{db_frac} dB\n"

  // --- Progress bar ---
  let progress_pct = if total_samples > 0 {
    current_pos.to_double() / total_samples.to_double()
  } else {
    0.0
  }
  let progress_width = num_bars
  let progress_filled = (progress_pct * progress_width.to_double()).to_int()
  output += "\u001b[36m"
  for i in 0..<progress_width {
    if i < progress_filled {
      output += "║"
    } else if i == progress_filled {
      output += "▓"
    } else {
      output += "░"
    }
  }
  output += "\u001b[0m "
  let pct_int = (progress_pct * 100.0).to_int()
  output += "\{pct_int}%  \{format_time(current_pos, sample_rate)} / \{format_time(total_samples, sample_rate)}\n"

  output
}
