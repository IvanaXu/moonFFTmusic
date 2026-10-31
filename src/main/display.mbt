// =============================================================================
// Terminal Display Module — Beautiful ANSI spectrum visualizer
// Visual enhancements:
//   1. Temporal smoothing — bars interpolate between frames
//   2. Row-level brightness gradient — 3D glow effect per bar
//   3. Left-side dB scale — professional meter look
//   4. Segmented RMS meter — green/yellow/red zones
//   5. Peak markers with gravity decay + bold
//   6. Separator line between header and spectrum
// =============================================================================

///|
let rainbow_palette : Array[Int32] = [
  21, 27, 33, 39, 45, 51, 50, 49, 48, 47, 46, 82, 118, 154, 190, 226, 215, 214, 213,
  208, 203, 204, 198, 199, 200, 201,
]

///|
let partial_blocks : Array[String] = [
  " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
]

///|
let ansi_clear : String = "\u001b[2J\u001b[H"

///|
let ansi_reset : String = "\u001b[0m"

///|
enum BarState {
  FullBlock
  PartialBlock(Int32)
  PeakMarker
  Empty
}

///|
fn palette_index(bar : Int32, num_bars : Int32) -> Int32 {
  (bar * (rainbow_palette.length() - 1) / num_bars).clamp(
    min=0,
    max=rainbow_palette.length() - 1,
  )
}

///|
fn gradient_color(bar : Int32, num_bars : Int32) -> String {
  let idx = palette_index(bar, num_bars)
  "\u001b[38;5;\{rainbow_palette[idx]}m"
}

///|
fn dim_color_code(color : Int32) -> Int32 {
  if color >= 16 && color <= 231 {
    let offset = color - 16
    let r = offset / 36
    let g = offset % 36 / 6
    let b = offset % 6
    16 + (r.max(1) - 1) * 36 + (g.max(1) - 1) * 6 + (b.max(1) - 1)
  } else {
    color
  }
}

///|
fn bright_color_code(color : Int32) -> Int32 {
  if color >= 16 && color <= 231 {
    let offset = color - 16
    let r = offset / 36
    let g = offset % 36 / 6
    let b = offset % 6
    16 + (r.min(5) + 1) * 36 + (g.min(5) + 1) * 6 + (b.min(5) + 1)
  } else {
    color
  }
}

///|
fn gradient_color_row(
  bar : Int32,
  num_bars : Int32,
  row : Int32,
  max_height : Int32,
) -> String {
  let idx = palette_index(bar, num_bars)
  let base_color = rainbow_palette[idx]
  let row_ratio = row.to_double() / max_height.to_double()
  let color = match row_ratio {
    r if r < 0.3 => bright_color_code(base_color)
    r if r < 0.7 => base_color
    _ => dim_color_code(base_color)
  }
  "\u001b[38;5;\{color}m"
}

///|
fn log_freq_bin(bar : Int32, num_bars : Int32, half_fft : Int32) -> Int32 {
  if half_fft <= 1 {
    return 0
  }
  let ratio = bar.to_double() / num_bars.to_double()
  let log_val = @math.pow(2.0, ratio * @math.log2(half_fft.to_double()))
  (log_val.to_int() - 1).clamp(min=0, max=half_fft - 1)
}

///|
fn freq_to_bar(
  freq : Double,
  num_bars : Int32,
  half_fft : Int32,
  sample_rate : Int32,
) -> Int32 {
  if freq <= 0.0 || half_fft <= 1 {
    return 0
  }
  let bin = freq * (half_fft * 2).to_double() / sample_rate.to_double()
  if bin <= 0.0 {
    return 0
  }
  let ratio = @math.log2(bin) / @math.log2(half_fft.to_double())
  (ratio * num_bars.to_double()).to_int().clamp(min=0, max=num_bars - 1)
}

///|
fn format_time(samples : Int32, sample_rate : Int32) -> String {
  let total_ms = samples * 1000 / sample_rate
  let minutes = total_ms / 60000
  let seconds = total_ms % 60000 / 1000
  let tenths = total_ms % 1000 / 100
  "\{minutes}:\{seconds}.\{tenths}"
}

///|
fn format_freq(hz : Int32) -> String {
  match hz {
    k if k >= 1000 => "\{k / 1000}kHz"
    _ => "\{hz}Hz"
  }
}

///|
fn scale_magnitude(mag : Double) -> Double {
  if mag > 0.0 {
    (@math.log10(mag * 1000.0 + 1.0) / 3.0).clamp(min=0.0, max=1.0)
  } else {
    0.0
  }
}

///|
fn bar_state(
  height : Int32,
  peak : Int32,
  level_top : Int32,
  level_bottom : Int32,
) -> BarState {
  if height >= level_top {
    FullBlock
  } else if height > level_bottom {
    let frac = height - level_bottom
    PartialBlock(frac.clamp(min=0, max=8))
  } else if peak >= level_top && peak > 0 {
    PeakMarker
  } else {
    Empty
  }
}

///|
fn render_horizontal_bar(
  sb : StringBuilder,
  filled : Int32,
  width : Int32,
  fill_char : String,
  empty_char : String,
  transition_char : String?,
) -> Unit {
  for i in 0..<width {
    match (i < filled, transition_char, i == filled) {
      (true, _, _) => sb.write_string(fill_char)
      (false, Some(tc), true) => sb.write_string(tc)
      _ => sb.write_string(empty_char)
    }
  }
}

///|
fn render_db_scale(sb : StringBuilder, row : Int32, max_height : Int32) -> Unit {
  let db_labels : Array[String] = [" 0dB", "-12", "-24", "-36", "-48"]
  let label_row = (row * (db_labels.length() - 1) / max_height).clamp(
    min=0,
    max=db_labels.length() - 1,
  )
  let expected_row = label_row * max_height / (db_labels.length() - 1)
  if row == expected_row {
    sb.write_string("\u001b[90m")
    sb.write_string(db_labels[label_row])
    sb.write_string("\u001b[0m ")
  } else {
    sb.write_string("\u001b[90m│\u001b[0m ")
  }
}

///|
fn render_spectrum(
  magnitudes : Array[Double],
  num_bars : Int32,
  max_height : Int32,
  sample_rate : Int32,
  fft_size : Int32,
  peak_heights : Array[Int32],
  peak_frames : Array[Int32],
  prev_heights : Array[Int32],
  current_pos : Int32,
  total_samples : Int32,
  rms_value : Double,
) -> String {
  let sb = StringBuilder::StringBuilder()
  let half_fft = fft_size / 2
  let sub_res = 8
  let max_levels = max_height * sub_res

  sb.write_string(ansi_clear)

  // --- Calculate bar heights ---
  let heights : Array[Int32] = Array::make(num_bars, 0)
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
      heights[bar] = (scale_magnitude(mag) * max_levels.to_double()).to_int()
    }
  }

  // --- Temporal smoothing: interpolate between previous and current ---
  for bar in 0..<num_bars {
    let prev = prev_heights[bar].to_double()
    let curr = heights[bar].to_double()
    let smoothed = prev * 0.6 + curr * 0.4
    heights[bar] = smoothed.to_int()
    prev_heights[bar] = heights[bar]
  }

  // --- Update peak hold with gravity decay ---
  for bar in 0..<num_bars {
    match (heights[bar] >= peak_heights[bar], peak_frames[bar] > 3) {
      (true, _) => {
        peak_heights[bar] = heights[bar]
        peak_frames[bar] = 0
      }
      (false, true) => {
        if peak_heights[bar] > 0 {
          peak_heights[bar] = peak_heights[bar] - sub_res / 2
        }
        peak_frames[bar] = 0
      }
      (false, false) => peak_frames[bar] = peak_frames[bar] + 1
    }
  }

  // --- Dominant frequency ---
  let dominant_freq = dominant_bin * sample_rate / fft_size

  // --- Box-drawing header ---
  let header_width = num_bars + 6
  let title = "🎵 MoonFFTmusic — Real-time Spectrum Analyzer"
  let info_line = "Rate: \{sample_rate}Hz | FFT: \{fft_size} | Bars: \{num_bars} | Peak: \{format_freq(dominant_freq)} | Time: \{format_time(current_pos, sample_rate)}"

  sb.write_string("\u001b[1;36m╔")
  for _ in 0..<header_width {
    sb.write_string("═")
  }
  sb.write_string("╗\n║ ")
  sb.write_string(title)
  let title_pad = (header_width - title.length() - 2).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<title_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n║ ")
  sb.write_string(info_line)
  let info_pad = (header_width - info_line.length() - 2).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<info_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n╚")
  for _ in 0..<header_width {
    sb.write_string("═")
  }
  sb.write_string("╝\n\u001b[0m")

  // --- Separator line ---
  sb.write_string("\u001b[90m")
  for _ in 0..<6 {
    sb.write_string("─")
  }
  for _ in 0..<num_bars {
    sb.write_string("─")
  }
  sb.write_string("\u001b[0m\n")

  // --- Render bars with dB scale and row-level brightness ---
  for row in 0..<max_height {
    render_db_scale(sb, row, max_height)
    let level_top = (max_height - row) * sub_res
    let level_bottom = (max_height - row - 1) * sub_res
    for bar in 0..<num_bars {
      match
        bar_state(heights[bar], peak_heights[bar], level_top, level_bottom) {
        FullBlock => {
          sb.write_string(gradient_color_row(bar, num_bars, row, max_height))
          sb.write_string("█")
        }
        PartialBlock(frac) => {
          sb.write_string(gradient_color_row(bar, num_bars, row, max_height))
          sb.write_string(partial_blocks[frac])
        }
        PeakMarker => {
          sb.write_string("\u001b[1m")
          sb.write_string(gradient_color(bar, num_bars))
          sb.write_string("▔")
          sb.write_string("\u001b[22m")
        }
        Empty => sb.write_string(" ")
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Frequency axis labels ---
  sb.write_string("\u001b[90m     ")
  let freq_labels : Array[Int32] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
  let mut label_line = ""
  let mut label_pos = 0
  for i in 0..<num_bars {
    let mut found_label = ""
    for j in 0..<freq_labels.length() {
      let target_bar = freq_to_bar(
        freq_labels[j].to_double(),
        num_bars,
        half_fft,
        sample_rate,
      )
      if target_bar == i {
        found_label = format_freq(freq_labels[j])
        break
      }
    }
    if found_label.length() > 0 {
      while label_pos < i {
        label_line += " "
        label_pos = label_pos + 1
      }
      label_line += found_label
      label_pos = i + found_label.length()
    }
  }
  sb.write_string(label_line)
  sb.write_string("\n\u001b[0m")

  // --- RMS volume meter with segmented color zones ---
  let rms_db = if rms_value > 0.0 {
    20.0 * @math.log10(rms_value)
  } else {
    -99.0
  }
  let rms_pct = if rms_value > 0.0 {
    ((rms_db + 60.0) / 60.0).clamp(min=0.0, max=1.0)
  } else {
    0.0
  }
  let meter_width = 20
  let meter_filled = (rms_pct * meter_width.to_double()).to_int()

  sb.write_string("\n\u001b[1;37mRMS: \u001b[0m[")
  for i in 0..<meter_width {
    let pct = i.to_double() / meter_width.to_double()
    match pct {
      p if p < 0.6 =>
        if i < meter_filled {
          sb.write_string("\u001b[32m█")
        } else {
          sb.write_string("\u001b[90m░")
        }
      p if p < 0.85 =>
        if i < meter_filled {
          sb.write_string("\u001b[33m█")
        } else {
          sb.write_string("\u001b[90m░")
        }
      _ =>
        if i < meter_filled {
          sb.write_string("\u001b[31m█")
        } else {
          sb.write_string("\u001b[90m░")
        }
    }
  }
  sb.write_string("\u001b[0m] ")
  let db_int = rms_db.to_int()
  let db_frac = ((rms_db - db_int.to_double()) * 10.0).abs().to_int()
  sb.write_string("\{db_int}.\{db_frac} dB\n")

  // --- Progress bar ---
  let progress_pct = if total_samples > 0 {
    current_pos.to_double() / total_samples.to_double()
  } else {
    0.0
  }
  let progress_filled = (progress_pct * num_bars.to_double()).to_int()

  sb.write_string("\u001b[36m")
  render_horizontal_bar(
    sb,
    progress_filled,
    num_bars,
    "║",
    "░",
    Some("▓"),
  )
  sb.write_string("\u001b[0m ")
  let pct_int = (progress_pct * 100.0).to_int()
  sb.write_string(
    "\{pct_int}%  \{format_time(current_pos, sample_rate)} / \{format_time(total_samples, sample_rate)}\n",
  )

  sb.to_string()
}
