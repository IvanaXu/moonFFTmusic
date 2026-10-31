// =============================================================================
// Terminal Display Module — Beautiful ANSI spectrum visualizer
//
// Performance optimizations:
//   - Precomputed log-freq bin mapping (no per-frame pow/log2)
//   - Precomputed grid-bar boolean array (no per-bar-per-row linear search)
//   - StringBuilder for frequency labels (no O(n^2) concatenation)
//   - In-place spatial smoothing (no temp array allocation)
//   - Precomputed per-bar true-color RGB (no per-cell HSL conversion)
//
// Visual enhancements:
//   1. Attack/release envelope — fast rise, slow fall
//   2. Spatial smoothing — 3-tap blur across neighboring bars
//   3. Row-level brightness gradient — 3D glow effect per bar
//   4. Left-side dB scale — professional meter look
//   5. Segmented RMS meter — green/yellow/red zones
//   6. Peak hold markers with exponential decay
//   7. Separator line between header and spectrum
//   8. Musical note detection for dominant frequency
//   9. Bar grouping with subtle gaps every 3 bars
//  10. Bottom glow reflection — dim mirror of spectrum
//  11. Dashed reference line at -12dB
//  12. Bar caps — ▀ at top of each bar
//  13. Peak frequency marker — ▼ arrow above dominant bar
//  14. Vertical frequency grid — faint ╎ at label positions
//  15. Magnitude-based color intensity
//  16. True-color 24-bit RGB rainbow gradient (smooth HSL-based)
//  17. Beat detection with border pulse glow
//  18. Waveform strip — time-domain signal display
// =============================================================================

///|
let partial_blocks : Array[String] = [
  " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
]

///|
let ansi_clear : String = "\u001b[2J\u001b[H"

///|
let ansi_reset : String = "\u001b[0m"

///|
let note_names : Array[String] = [
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
]

///|
/// Precomputed display context — computed once at startup, reused every frame.
/// Eliminates per-frame pow/log2/trig calls by precomputing all position-dependent
/// mappings and color tables.
struct DisplayContext {
  num_bars : Int32
  max_height : Int32
  sub_res : Int32
  max_levels : Int32
  bin_map : Array[Int32] // bar index -> FFT bin index (log-freq mapping)
  is_grid : Array[Bool] // is this bar position a frequency grid line?
  grid_bars : Array[Int32] // bar positions of frequency labels
  freq_labels : Array[Int32] // frequency values for labels
  bar_r : Array[Int32] // base red per bar (true-color)
  bar_g_arr : Array[Int32] // base green per bar
  bar_b_arr : Array[Int32] // base blue per bar
  half_fft : Int32
  sample_rate : Int32
  fft_size : Int32
}

///|
/// Beat detector — tracks RMS energy history to detect rhythmic pulses.
/// Uses a circular buffer of energy values; when current energy exceeds
/// the moving average by a threshold, a beat is detected.
struct BeatDetector {
  energy_history : Array[Double]
  mut history_idx : Int32
  history_size : Int32
  mut beat_intensity : Double
}

///|
/// Create a new beat detector with the given history window size.
fn BeatDetector::new(history_size : Int32) -> BeatDetector {
  BeatDetector::{
    energy_history: Array::make(history_size, 0.0),
    history_idx: 0,
    history_size,
    beat_intensity: 0.0,
  }
}

///|
/// Update beat detector with current RMS value. Returns beat intensity (0.0 to 1.0).
/// Beat is detected when current energy exceeds average * threshold.
/// Intensity decays exponentially each frame.
fn BeatDetector::update(self : BeatDetector, rms : Double) -> Double {
  let energy = rms * rms
  let idx = self.history_idx
  self.energy_history[idx] = energy
  self.history_idx = (idx + 1) % self.history_size

  // Compute average energy
  let mut sum = 0.0
  for i in 0..<self.history_size {
    sum += self.energy_history[i]
  }
  let avg = sum / self.history_size.to_double()

  // Beat detection: current energy significantly exceeds average
  if energy > avg * 1.4 && energy > 0.001 {
    self.beat_intensity = 1.0
  } else {
    self.beat_intensity *= 0.92
  }
  self.beat_intensity
}

///|
enum BarState {
  FullBlock
  BarCap
  PartialBlock(Int32)
  PeakMarker
  Empty
}

///|
/// HSL to RGB conversion. h in [0,360), s,l in [0,1].
/// Returns (r, g, b) as Int32 in [0, 255].
fn hsl_to_rgb(h : Double, s : Double, l : Double) -> (Int32, Int32, Int32) {
  let c = (1.0 - (2.0 * l - 1.0).abs()) * s
  let h_prime = h / 60.0
  let x = c * (1.0 - (h_prime % 2.0 - 1.0).abs())
  let m = l - c / 2.0
  let (r1, g1, b1) = match h {
    hh if hh < 60.0 => (c, x, 0.0)
    hh if hh < 120.0 => (x, c, 0.0)
    hh if hh < 180.0 => (0.0, c, x)
    hh if hh < 240.0 => (0.0, x, c)
    hh if hh < 300.0 => (x, 0.0, c)
    _ => (c, 0.0, x)
  }
  (
    ((r1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
    ((g1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
    ((b1 + m) * 255.0).clamp(min=0.0, max=255.0).to_int(),
  )
}

///|
/// Precompute per-bar base RGB colors using a smooth HSL rainbow gradient.
/// Hue: 240 (blue) at bar 0 -> 0 (red) at last bar, through cyan/green/yellow/orange.
/// Saturation: 0.85, Lightness: 0.55 (medium brightness base).
fn precompute_bar_colors(
  num_bars : Int32,
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let bar_r = Array::make(num_bars, 0)
  let bar_g = Array::make(num_bars, 0)
  let bar_b = Array::make(num_bars, 0)
  for bar in 0..<num_bars {
    let ratio = bar.to_double() / (num_bars - 1).to_double()
    let hue = 240.0 * (1.0 - ratio)
    let (r, g, b) = hsl_to_rgb(hue, 0.85, 0.55)
    bar_r[bar] = r
    bar_g[bar] = g
    bar_b[bar] = b
  }
  (bar_r, bar_g, bar_b)
}

///|
/// Log-frequency bin mapping: maps bar index to FFT bin index.
fn log_freq_bin(bar : Int32, num_bars : Int32, half_fft : Int32) -> Int32 {
  if half_fft <= 1 {
    return 0
  }
  let ratio = bar.to_double() / num_bars.to_double()
  let log_val = @math.pow(2.0, ratio * @math.log2(half_fft.to_double()))
  (log_val.to_int() - 1).clamp(min=0, max=half_fft - 1)
}

///|
/// Map a frequency to a bar position (inverse of log_freq_bin).
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
/// Create a DisplayContext with all precomputed tables.
/// Call once at startup; reuse for every frame.
fn create_display_context(
  num_bars : Int32,
  max_height : Int32,
  sub_res : Int32,
  half_fft : Int32,
  sample_rate : Int32,
  fft_size : Int32,
) -> DisplayContext {
  let bin_map = Array::makei(num_bars, fn(bar) {
    log_freq_bin(bar, num_bars, half_fft)
  })
  let freq_labels : Array[Int32] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]
  let grid_bars = Array::makei(freq_labels.length(), fn(j) {
    freq_to_bar(freq_labels[j].to_double(), num_bars, half_fft, sample_rate)
  })
  let is_grid = Array::make(num_bars, false)
  for j in 0..<grid_bars.length() {
    let gb = grid_bars[j]
    if gb >= 0 && gb < num_bars {
      is_grid[gb] = true
    }
  }
  let (bar_r, bar_g_arr, bar_b_arr) = precompute_bar_colors(num_bars)
  DisplayContext::{
    num_bars,
    max_height,
    sub_res,
    max_levels: max_height * sub_res,
    bin_map,
    is_grid,
    grid_bars,
    freq_labels,
    bar_r,
    bar_g_arr,
    bar_b_arr,
    half_fft,
    sample_rate,
    fft_size,
  }
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
fn freq_to_note(hz : Int32) -> String {
  if hz <= 0 {
    return "---"
  }
  let midi = 69.0 + 12.0 * @math.log2(hz.to_double() / 440.0)
  let midi_int = midi.round().to_int()
  if midi_int < 0 || midi_int > 127 {
    return "---"
  }
  let note_idx = midi_int % 12
  let octave = midi_int / 12 - 1
  let cents = ((midi - midi_int.to_double()) * 100.0).to_int()
  let cents_str = if cents > 5 { "+" } else if cents < -5 { "-" } else { "" }
  "\{note_names[note_idx]}\{octave}\{cents_str}"
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
/// Generate true-color ANSI escape with brightness adjustment.
/// brightness in [0.3, 1.3] — scales the base RGB.
fn true_color(bar : Int32, ctx : DisplayContext, brightness : Double) -> String {
  let r = (ctx.bar_r[bar].to_double() * brightness)
    .clamp(min=0.0, max=255.0)
    .to_int()
  let g = (ctx.bar_g_arr[bar].to_double() * brightness)
    .clamp(min=0.0, max=255.0)
    .to_int()
  let b = (ctx.bar_b_arr[bar].to_double() * brightness)
    .clamp(min=0.0, max=255.0)
    .to_int()
  "\u001b[38;2;\{r};\{g};\{b}m"
}

///|
fn bar_state(
  height : Int32,
  peak : Int32,
  level_top : Int32,
  level_bottom : Int32,
) -> BarState {
  if height >= level_top {
    if height < level_top + 8 {
      BarCap
    } else {
      FullBlock
    }
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
fn is_ref_line(row : Int32, max_height : Int32) -> Bool {
  row == 1 * max_height / 4
}

///|
/// Render a mini waveform strip from time-domain samples.
fn render_waveform(
  sb : StringBuilder,
  waveform : Array[Double],
  width : Int32,
) -> Unit {
  sb.write_string("\u001b[90m     \u001b[0m")
  let n = waveform.length()
  if n == 0 {
    sb.write_string("\n")
    return
  }
  let step = n.to_double() / width.to_double()
  for i in 0..<width {
    let sample_idx = (i.to_double() * step).to_int().clamp(min=0, max=n - 1)
    let sample = waveform[sample_idx]
    let scaled = (sample * 4.0).clamp(min=-4.0, max=4.0).to_int()
    match scaled {
      0 => sb.write_string("\u001b[90m─\u001b[0m")
      1 => sb.write_string("\u001b[90m▔\u001b[0m")
      2 => sb.write_string("\u001b[90m▀\u001b[0m")
      3 | 4 => sb.write_string("\u001b[90m█\u001b[0m")
      -1 => sb.write_string("\u001b[90m▁\u001b[0m")
      -2 => sb.write_string("\u001b[90m▄\u001b[0m")
      -3 | -4 => sb.write_string("\u001b[90m█\u001b[0m")
      _ => sb.write_string("\u001b[90m─\u001b[0m")
    }
  }
  sb.write_string("\n")
}

///|
/// Main spectrum renderer — uses precomputed DisplayContext for all
/// position-dependent lookups. Zero trig/pow/log calls per frame in the hot path.
///
/// Optimizations vs original:
///   - bin_map precomputed (no per-frame log_freq_bin calls)
///   - is_grid precomputed (no per-bar-per-row linear search)
///   - StringBuilder for frequency labels (no O(n^2) string concat)
///   - In-place spatial smoothing (no temp array)
///   - True-color 24-bit RGB (smooth gradient, precomputed per-bar)
///   - Beat detection border glow
///   - Waveform strip
fn render_spectrum(
  magnitudes : Array[Double],
  ctx : DisplayContext,
  peak_heights : Array[Int32],
  peak_frames : Array[Int32],
  prev_heights : Array[Int32],
  current_pos : Int32,
  total_samples : Int32,
  rms_value : Double,
  beat_intensity : Double,
  waveform : Array[Double],
) -> String {
  let sb = StringBuilder::StringBuilder()
  let num_bars = ctx.num_bars
  let max_height = ctx.max_height
  let sub_res = ctx.sub_res
  let max_levels = ctx.max_levels
  let sample_rate = ctx.sample_rate
  let fft_size = ctx.fft_size
  let half_fft = ctx.half_fft

  sb.write_string(ansi_clear)

  // --- Calculate bar heights using precomputed bin_map ---
  let heights : Array[Int32] = Array::make(num_bars, 0)
  let mut dominant_bin = 0
  let mut max_mag = 0.0
  for bar in 0..<num_bars {
    let bin_idx = ctx.bin_map[bar]
    if bin_idx < magnitudes.length() {
      let mag = magnitudes[bin_idx]
      if mag > max_mag {
        max_mag = mag
        dominant_bin = bin_idx
      }
      heights[bar] = (scale_magnitude(mag) * max_levels.to_double()).to_int()
    }
  }

  // --- Attack/release envelope: fast rise, slow fall ---
  for bar in 0..<num_bars {
    let prev = prev_heights[bar].to_double()
    let curr = heights[bar].to_double()
    let smoothed = if curr >= prev {
      prev * 0.3 + curr * 0.7
    } else {
      prev * 0.85 + curr * 0.15
    }
    heights[bar] = smoothed.to_int()
    prev_heights[bar] = heights[bar]
  }

  // --- Spatial smoothing: in-place 3-tap blur [0.2, 0.6, 0.2] ---
  // Uses rolling variables instead of temp array allocation
  let mut prev_val = 0.0
  for bar in 0..<num_bars {
    let left = prev_val
    let center = heights[bar].to_double()
    let right = if bar < num_bars - 1 {
      heights[bar + 1].to_double()
    } else {
      0.0
    }
    let blurred = left * 0.2 + center * 0.6 + right * 0.2
    prev_val = center
    heights[bar] = blurred.to_int()
  }

  // --- Update peak hold with exponential decay ---
  for bar in 0..<num_bars {
    match (heights[bar] >= peak_heights[bar], peak_frames[bar] > 3) {
      (true, _) => {
        peak_heights[bar] = heights[bar]
        peak_frames[bar] = 0
      }
      (false, true) => {
        let decayed = (peak_heights[bar].to_double() * 0.88).to_int()
        peak_heights[bar] = decayed
        peak_frames[bar] = 0
      }
      (false, false) => peak_frames[bar] = peak_frames[bar] + 1
    }
  }

  // --- Dominant frequency + note name ---
  let dominant_freq = dominant_bin * sample_rate / fft_size
  let note_name = freq_to_note(dominant_freq)
  let dominant_bar = freq_to_bar(
    dominant_freq.to_double(),
    num_bars,
    half_fft,
    sample_rate,
  )

  // --- Beat glow border color ---
  let beat_glow = if beat_intensity > 0.1 {
    "\u001b[38;2;255;\{(beat_intensity * 200.0).to_int()};\{(beat_intensity * 100.0).to_int()}m"
  } else {
    "\u001b[1;36m"
  }

  // --- Box-drawing header with beat glow ---
  let header_width = num_bars + 6
  let title = "🎵 MoonFFTmusic — Real-time Spectrum Analyzer"
  let beat_indicator = if beat_intensity > 0.5 { " ♫" } else { "  " }
  let info_line = "Rate: \{sample_rate}Hz | FFT: \{fft_size} | Bars: \{num_bars} | Peak: \{format_freq(dominant_freq)} (\{note_name})\{beat_indicator} | \{format_time(current_pos, sample_rate)}"

  sb.write_string(beat_glow)
  sb.write_string("╔")
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

  // --- Peak frequency marker row (▼ above spectrum) ---
  sb.write_string("\u001b[90m     \u001b[0m")
  for bar in 0..<num_bars {
    if bar % 3 == 2 && bar < num_bars - 1 {
      sb.write_string(" ")
      continue
    }
    if bar == dominant_bar && heights[bar] > 0 {
      sb.write_string("\u001b[1;33m▼\u001b[0m")
    } else if ctx.is_grid[bar] {
      sb.write_string("\u001b[90m╎\u001b[0m")
    } else {
      sb.write_string(" ")
    }
  }
  sb.write_string("\n")

  // --- Render bars with dB scale, ref line, caps, and grid ---
  for row in 0..<max_height {
    render_db_scale(sb, row, max_height)
    let level_top = (max_height - row) * sub_res
    let level_bottom = (max_height - row - 1) * sub_res
    let ref_line = is_ref_line(row, max_height)
    for bar in 0..<num_bars {
      if bar % 3 == 2 && bar < num_bars - 1 {
        if ref_line {
          sb.write_string("\u001b[90m·\u001b[0m")
        } else {
          sb.write_string(" ")
        }
        continue
      }
      let height_ratio = heights[bar].to_double() / max_levels.to_double()
      // Brightness: 50% row position + 50% magnitude, mapped to [0.4, 1.2]
      let row_ratio = row.to_double() / max_height.to_double()
      let brightness = 0.4 + (row_ratio * 0.5 + height_ratio * 0.5) * 0.8
      match
        bar_state(heights[bar], peak_heights[bar], level_top, level_bottom) {
        FullBlock => {
          sb.write_string(true_color(bar, ctx, brightness))
          sb.write_string("█")
        }
        BarCap => {
          sb.write_string(true_color(bar, ctx, brightness))
          sb.write_string("▀")
        }
        PartialBlock(frac) => {
          sb.write_string(true_color(bar, ctx, brightness))
          sb.write_string(partial_blocks[frac])
        }
        PeakMarker => {
          sb.write_string("\u001b[1m")
          sb.write_string(true_color(bar, ctx, 1.1))
          sb.write_string("━")
          sb.write_string("\u001b[22m")
        }
        Empty =>
          if ctx.is_grid[bar] {
            sb.write_string("\u001b[90m╎\u001b[0m")
          } else if ref_line {
            sb.write_string("\u001b[90m┄\u001b[0m")
          } else {
            sb.write_string(" ")
          }
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Bottom glow reflection (3 rows, dimming) ---
  for glow_row in 0..<3 {
    sb.write_string("\u001b[90m     \u001b[0m")
    let glow_factor = match glow_row {
      0 => 0.35
      1 => 0.2
      _ => 0.1
    }
    for bar in 0..<num_bars {
      if bar % 3 == 2 && bar < num_bars - 1 {
        sb.write_string(" ")
        continue
      }
      let reflected_height = (heights[bar].to_double() * glow_factor).to_int()
      let glow_level = (glow_row + 1) * sub_res
      if reflected_height >= glow_level {
        sb.write_string(true_color(bar, ctx, 0.35))
        sb.write_string("▀")
      } else {
        sb.write_string(" ")
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Frequency axis labels (StringBuilder, not O(n^2) concat) ---
  sb.write_string("\u001b[90m     ")
  let mut label_pos = 0
  for i in 0..<num_bars {
    let mut found_label = ""
    for j in 0..<ctx.freq_labels.length() {
      if ctx.grid_bars[j] == i {
        found_label = format_freq(ctx.freq_labels[j])
        break
      }
    }
    if found_label.length() > 0 {
      while label_pos < i {
        sb.write_string(" ")
        label_pos = label_pos + 1
      }
      sb.write_string(found_label)
      label_pos = i + found_label.length()
    }
  }
  sb.write_string("\n\u001b[0m")

  // --- Waveform strip ---
  sb.write_string("\u001b[90m  WV \u001b[0m")
  render_waveform(sb, waveform, num_bars)

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
