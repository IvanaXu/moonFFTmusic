// =============================================================================
// Terminal Display Module — Beautiful ANSI spectrum visualizer
//
// Optimized display effects:
//   - Continuous spectrum (no bar grouping gaps) for seamless visual flow
//   - 32-level brightness gradient (smoother color transitions)
//   - Enhanced HSL color gradient with variable saturation/lightness
//   - Power-curve magnitude scaling for better dynamic range
//   - Richer bottom glow reflection with proper bar colors
//   - Smoother attack/release envelope and spatial smoothing
//   - True-color waveform with amplitude-based coloring
//   - Precomputed color string table [bar][level] — eliminates per-frame
//     string formatting calls
//   - Beat-reactive brightness boost and border glow
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
/// Terminal display width of a single character (0, 1 or 2 columns).
/// Handles combining marks (0), East-Asian wide/fullwidth and emoji (2).
fn char_display_width(c : Char) -> Int32 {
  let cp = c.to_int()
  if cp == 0 {
    return 0
  }
  // Zero-width: combining marks and format characters
  if (cp >= 0x300 && cp <= 0x36F) ||
    (cp >= 0x1AB0 && cp <= 0x1AFF) ||
    (cp >= 0x1DC0 && cp <= 0x1DFF) ||
    (cp >= 0x200B && cp <= 0x200F) ||
    (cp >= 0xFE00 && cp <= 0xFE0F) {
    return 0
  }
  // Double-width: CJK, Hangul, fullwidth forms and emoji
  if (cp >= 0x1100 && cp <= 0x115F) ||
    (cp >= 0x2E80 && cp <= 0x2EFF) ||
    (cp >= 0x3000 && cp <= 0x303E) ||
    (cp >= 0x3041 && cp <= 0x33FF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0x4E00 && cp <= 0x9FFF) ||
    (cp >= 0xA000 && cp <= 0xA4CF) ||
    (cp >= 0xAC00 && cp <= 0xD7A3) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFE30 && cp <= 0xFE4F) ||
    (cp >= 0xFF00 && cp <= 0xFF60) ||
    (cp >= 0xFFE0 && cp <= 0xFFE6) ||
    (cp >= 0x1F300 && cp <= 0x1FAFF) ||
    (cp >= 0x20000 && cp <= 0x3FFFD) {
    return 2
  }
  1
}

///|
/// Terminal display width of a string (sum of per-character widths).
/// Must be used instead of `String::length()` whenever the text may contain
/// emoji / wide characters, otherwise ANSI-framed layouts become misaligned.
fn display_width(s : String) -> Int32 {
  let mut w = 0
  for c in s {
    w += char_display_width(c)
  }
  w
}

///|
/// Truncate a string to at most `max_w` display columns, appending an ellipsis
/// when content is dropped. Ensures framed rows never overflow their border.
fn truncate_to_width(s : String, max_w : Int32) -> String {
  if display_width(s) <= max_w {
    return s
  }
  let limit = if max_w > 1 { max_w - 1 } else { max_w }
  let mut out = ""
  let mut w = 0
  for c in s {
    let cw = char_display_width(c)
    if w + cw > limit {
      break
    }
    out = out + "\{c}"
    w += cw
  }
  if max_w > 1 {
    out = out + "…"
  }
  out
}

///|
let note_names : Array[String] = [
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
]

///|
let num_brightness_levels : Int32 = 32

///|
/// Precomputed display context — computed once at startup, reused every frame.
struct DisplayContext {
  num_bars : Int32
  max_height : Int32
  sub_res : Int32
  max_levels : Int32
  bin_map : Array[Int32]
  bin_starts : Array[Int32]
  bin_ends : Array[Int32]
  is_grid : Array[Bool]
  color_tables : Array[Array[String]]
  mut color_table_idx : Int32
  row_contrib : Array[Double]
  heights_d : Array[Double]
  peak_heights_d : Array[Double]
  height_factor : Double
  sample_rate : Int32
  fft_size : Int32
  meter_colors : Array[String]
  label_strings : Array[String]
  // Stable (non-rotating) colors for the frequency axis labels
  label_colors : Array[String]
  db_scale_labels : Array[String]
  waveform_colors : Array[String]
  bar_offsets : Array[Int32]
  // Spectrogram waterfall: 3 rows of history
  spectrogram_history : Array[Array[Int32]]
  mut spectrogram_idx : Int32
  // Precomputed spectrogram waterfall background tables (per-bar hue, rotating)
  spectrogram_bg_tables : Array[Array[String]]
  // Auto-gain control
  mut auto_gain : Double
  // Band meter colors (green→yellow→red, 10 levels)
  band_colors : Array[String]
  // Progress-bar colors (cool cyan→violet ramp along the bar)
  progress_colors : Array[String]
}

///|
struct BeatDetector {
  energy_history : Array[Double]
  mut history_idx : Int32
  history_size : Int32
  mut beat_intensity : Double
  mut energy_sum : Double
  // Number of samples actually written into energy_history so far (caps at
  // history_size). Used so the average is taken over real data, not zero-padded.
  mut filled : Int32
  // BPM estimation
  beat_intervals : Array[Double]
  mut beat_intervals_idx : Int32
  beat_intervals_size : Int32
  mut last_beat_time : Double
  mut bpm : Double
  mut beat_pulse : Double
  // Total detected beats — drives the 4-step rhythm indicator
  mut beat_count : Int32
  // EMA of recent detected-beat energies — gauges accent (loud) vs soft beats
  mut beat_env : Double
}

///|
fn BeatDetector::new(history_size : Int32) -> BeatDetector {
  BeatDetector::{
    energy_history: Array::make(history_size, 0.0),
    history_idx: 0,
    history_size,
    beat_intensity: 0.0,
    energy_sum: 0.0,
    filled: 0,
    beat_intervals: Array::make(8, 0.0),
    beat_intervals_idx: 0,
    beat_intervals_size: 8,
    last_beat_time: 0.0,
    bpm: 0.0,
    beat_pulse: 0.0,
    beat_count: 0,
    beat_env: 0.0,
  }
}

///|
fn BeatDetector::update(
  self : BeatDetector,
  rms : Double,
  current_time : Double,
) -> Double {
  let energy = rms * rms
  let idx = self.history_idx
  self.energy_sum -= self.energy_history[idx]
  self.energy_history[idx] = energy
  self.energy_sum += energy
  self.history_idx = (idx + 1) % self.history_size
  if self.filled < self.history_size {
    self.filled = self.filled + 1
  }
  // Average over the samples collected so far. Dividing by the full window
  // while it was still filling up under-estimated the average, which made
  // steady sounds register as beats and flash the border/UI at startup.
  let avg = self.energy_sum / self.filled.to_double()
  // Beat detection with cooldown: minimum 0.15s between beats
  let time_since_last = current_time - self.last_beat_time
  let is_beat = self.filled >= 8 &&
    energy > avg * 1.4 &&
    energy > 0.001 &&
    time_since_last > 0.15
  if is_beat {
    self.beat_intensity = 1.0
    // Accent gauge: compare this beat against the recent beat envelope so
    // louder beats flash brighter than soft ones — the display conveys the
    // groove, not merely the tempo.
    if self.beat_env <= 0.0 || energy > self.beat_env {
      self.beat_env = energy
    } else {
      self.beat_env = self.beat_env * 0.94
    }
    let strength = (energy / self.beat_env).clamp(min=0.5, max=1.0)
    // BPM estimation: record beat interval
    if self.last_beat_time > 0.0 {
      let interval = time_since_last
      // Only accept intervals between 0.15s (400 BPM) and 2.0s (30 BPM)
      if interval > 0.15 && interval < 2.0 {
        let bi_idx = self.beat_intervals_idx
        self.beat_intervals[bi_idx] = interval
        self.beat_intervals_idx = (bi_idx + 1) % self.beat_intervals_size
        // Compute average interval → BPM
        let mut sum = 0.0
        let mut count = 0
        for i in 0..<self.beat_intervals_size {
          let v = self.beat_intervals[i]
          if v > 0.0 {
            sum += v
            count += 1
          }
        }
        if count > 0 {
          self.bpm = 60.0 / (sum / count.to_double())
        }
      }
    }
    self.last_beat_time = current_time
    // Pulse amplitude reflects beat strength: accents hit the full white-hot
    // flash, soft beats only a gentler warm one (0.5..1.0).
    self.beat_pulse = strength
    self.beat_count = self.beat_count + 1
  } else {
    self.beat_intensity *= 0.92
    // Sharper pulse decay (~0.25 s) so beat flashes read as crisp hits that
    // return to calm well before the next beat at common tempos.
    self.beat_pulse *= 0.78
  }
  self.beat_intensity
}

///|
/// Bar top connector character — based on height difference with neighbors.
/// Uses MoonBit `match` for character selection: ─ ╱ ╲ ╳
fn connector_char(left_h : Int32, curr_h : Int32, right_h : Int32) -> String {
  let diff_r = right_h - curr_h
  let diff_l = curr_h - left_h
  // Threshold=6 creates a wider dead zone, preventing ╱↔─↔╲ flicker
  // when neighboring bar heights oscillate within a small range.
  match (diff_l, diff_r) {
    (dl, dr) if dl > 6 && dr > 6 => "╱" // rising →
    (dl, dr) if dl < -6 && dr < -6 => "╲" // falling →
    (dl, dr) if dl > 6 && dr < -6 => "╳" // peak
    (dl, dr) if dl < -6 && dr > 6 => "╳" // valley
    _ => "─" // similar height — flat connector
  }
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
fn precompute_bar_colors(
  num_bars : Int32,
) -> (Array[Double], Array[Double], Array[Double]) {
  let bar_hues = Array::make(num_bars, 0.0)
  let bar_sats = Array::make(num_bars, 0.0)
  let bar_lights = Array::make(num_bars, 0.0)
  for bar in 0..<num_bars {
    let ratio = bar.to_double() / (num_bars - 1).to_double()
    // Hue: 260 (indigo) -> 0 (red), wide vibrant spectrum
    let hue = 260.0 * (1.0 - ratio)
    // Saturation: vivid across the board, peaking slightly in the mid-range
    let sat = 0.82 + 0.16 * (1.0 - (2.0 * ratio - 1.0).abs())
    // Lightness: slightly darker at bass, brighter at treble
    let light = 0.45 + 0.17 * ratio
    bar_hues[bar] = hue
    bar_sats[bar] = sat
    bar_lights[bar] = light
  }
  (bar_hues, bar_sats, bar_lights)
}

///|

///|
/// Precompute 40 color tables with hue rotation (3 degrees per step).
/// 40 tables × 60 bars × 32 levels = 76,800 strings (~1.5MB) at startup.
/// Per-frame: zero allocations — just swap the table index.
fn precompute_color_tables(
  bar_hues : Array[Double],
  bar_sats : Array[Double],
  bar_lights : Array[Double],
  num_bars : Int32,
  num_tables : Int32,
  hue_step : Double,
) -> Array[Array[String]] {
  let nbl = num_brightness_levels
  let tables = Array::make(num_tables, Array::make(0, ""))
  for tbl_idx in 0..<num_tables {
    let hue_offset = tbl_idx.to_double() * hue_step
    let table = Array::make(num_bars * nbl, "")
    for bar in 0..<num_bars {
      let hue = bar_hues[bar] + hue_offset
      let sat = bar_sats[bar]
      let light = bar_lights[bar]
      // Vertical hue gradient: a deeper hue at the base, a brighter hue at the
      // top (±18°), so each column reads as a glowing neon tube instead of a
      // flat fill. Colour still means frequency — the pair is anchored to the bar.
      let (br0, bg0, bb0) = hsl_to_rgb(hue - 18.0, sat, light)
      let (br1, bg1, bb1) = hsl_to_rgb(hue + 18.0, sat, light)
      let bar_off = bar * nbl
      for level in 0..<nbl {
        let lr = level.to_double() / (nbl - 1).to_double()
        let brightness = 0.22 + lr * 0.78
        // Neon glow: the hottest cells blend slightly toward white, giving each
        // bar a bright glowing core instead of flat saturated color.
        let glow = lr * lr * 0.18
        let rr = (br0.to_double() + (br1 - br0).to_double() * lr) * brightness
        let gg = (bg0.to_double() + (bg1 - bg0).to_double() * lr) * brightness
        let bb = (bb0.to_double() + (bb1 - bb0).to_double() * lr) * brightness
        let r = (rr + (255.0 - rr) * glow).clamp(min=0.0, max=255.0).to_int()
        let g = (gg + (255.0 - gg) * glow).clamp(min=0.0, max=255.0).to_int()
        let b = (bb + (255.0 - bb) * glow).clamp(min=0.0, max=255.0).to_int()
        table.unsafe_set(bar_off + level, "\u001b[38;2;\{r};\{g};\{b}m")
      }
    }
    tables[tbl_idx] = table
  }
  tables
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

///|
/// Precompute spectrogram waterfall background cells (per bar × level).
/// Hue follows the SAME per-bar rainbow as the bars (color = frequency), and
/// the tables rotate in lockstep with the bar color tables, so each frequency
/// column keeps a continuous hue from the live bars down through the waterfall.
/// Brightness carries intensity (dimmer than the bars, so history recedes).
/// Each entry ends with a trailing space so it fills one terminal cell.
fn precompute_spectro_bg_tables(
  bar_hues : Array[Double],
  bar_sats : Array[Double],
  bar_lights : Array[Double],
  num_bars : Int32,
  num_tables : Int32,
  hue_step : Double,
) -> Array[Array[String]] {
  let nbl = num_brightness_levels
  let tables = Array::make(num_tables, Array::make(0, ""))
  for tbl_idx in 0..<num_tables {
    let hue_offset = tbl_idx.to_double() * hue_step
    let table = Array::make(num_bars * nbl, "")
    for bar in 0..<num_bars {
      let hue = bar_hues[bar] + hue_offset
      // Same vertical hue gradient as the live bars, so a column keeps a
      // continuous colour from the spectrum down through the history rows.
      let (br0, bg0, bb0) = hsl_to_rgb(
        hue - 18.0,
        bar_sats[bar],
        bar_lights[bar],
      )
      let (br1, bg1, bb1) = hsl_to_rgb(
        hue + 18.0,
        bar_sats[bar],
        bar_lights[bar],
      )
      let bar_off = bar * nbl
      for level in 0..<nbl {
        let lr = level.to_double() / (nbl - 1).to_double()
        let brightness = 0.15 + lr * 0.66
        let r = ((br0.to_double() + (br1 - br0).to_double() * lr) * brightness)
          .clamp(min=0.0, max=255.0)
          .to_int()
        let g = ((bg0.to_double() + (bg1 - bg0).to_double() * lr) * brightness)
          .clamp(min=0.0, max=255.0)
          .to_int()
        let b = ((bb0.to_double() + (bb1 - bb0).to_double() * lr) * brightness)
          .clamp(min=0.0, max=255.0)
          .to_int()
        table.unsafe_set(bar_off + level, "\u001b[48;2;\{r};\{g};\{b}m ")
      }
    }
    tables[tbl_idx] = table
  }
  tables
}

///|
/// Piano keyboard is_black pattern for 12 semitones starting from C
/// C=white, C#=black, D=white, D#=black, E=white, F=white,
/// F#=black, G=white, G#=black, A=white, A#=black, B=white
fn piano_key_is_black(semitone : Int32) -> Bool {
  match semitone % 12 {
    1 | 3 | 6 | 8 | 10 => true
    _ => false
  }
}

///|
/// Render piano keyboard — 2 octaves (24 semitones) from C3 (MIDI 48)
fn render_piano_keyboard(
  sb : StringBuilder,
  dom_midi : Int32,
  beat_pulse : Double,
  beat_count : Int32,
) -> Unit {
  // 2 octaves starting from MIDI 48 (C3)
  let start_midi = 48
  let num_keys = 24
  sb.write_string("\u001b[90m   \u001b[35m\u{1F3B9}\u001b[0m ")
  for i in 0..<num_keys {
    let midi = start_midi + i
    let is_black = piano_key_is_black(i)
    if midi == dom_midi {
      // Detected note — bright yellow highlight
      sb.write_string("\u001b[1;33m\u{25BC}\u001b[0m")
    } else if is_black {
      // Black key — medium purple (brightened for visibility on dark terminals)
      sb.write_string("\u001b[38;2;120;90;155m\u{2502}\u001b[0m")
    } else {
      // White key — cool blue-gray (brightened for visibility)
      sb.write_string("\u001b[38;2;100;110;140m\u{2502}\u001b[0m")
    }
  }
  // Show octave labels
  sb.write_string(" \u001b[90mC3-C5\u001b[0m")
  // Beat pulse indicator
  if beat_pulse > 0.3 {
    sb.write_string(" \u001b[1;31m\u{2665}\u001b[0m")
  } else {
    sb.write_string(" \u001b[90m\u{2661}\u001b[0m")
  }
  // 4-step rhythm indicator: the lit cell advances with each detected beat so
  // tempo reads as motion, and it flares on the beat pulse.
  if beat_count > 0 {
    sb.write_string("  ")
    let step = beat_count % 4
    for i in 0..<4 {
      if i == step {
        if beat_pulse > 0.5 {
          sb.write_string("\u001b[1;31m\u{25CF}\u001b[0m")
        } else {
          sb.write_string("\u001b[31m\u{25CF}\u001b[0m")
        }
      } else {
        sb.write_string("\u001b[90m\u{25CB}\u001b[0m")
      }
    }
  }
  sb.write_string("\n")
}

///|
/// Render frequency band meters — BASS / MID / TREBLE energy levels
fn render_band_meters(
  sb : StringBuilder,
  magnitudes : Array[Double],
  num_bars : Int32,
  band_colors : Array[String],
) -> Unit {
  // BASS: bars 0-9, MID: bars 10-29, TREBLE: bars 30-59
  let mut bass_max = 0.0
  for i in 0..<10 {
    let m = magnitudes.unsafe_get(i)
    if m > bass_max {
      bass_max = m
    }
  }
  let mut mid_max = 0.0
  for i in 10..<30 {
    let m = magnitudes.unsafe_get(i)
    if m > mid_max {
      mid_max = m
    }
  }
  let mut treble_max = 0.0
  for i in 30..<num_bars {
    let m = magnitudes.unsafe_get(i)
    if m > treble_max {
      treble_max = m
    }
  }
  // Normalize to the strongest band this frame. Raw FFT magnitudes are large
  // (up to ~512), so the old absolute `max_val * 10` pegged every active band
  // to full and the meters never showed gradation. Relative levels make the
  // three bands comparable and allow partial fills to appear.
  let frame_max = if bass_max > mid_max {
    if bass_max > treble_max {
      bass_max
    } else {
      treble_max
    }
  } else if mid_max > treble_max {
    mid_max
  } else {
    treble_max
  }
  let bands = [("BASS", bass_max), ("MID ", mid_max), ("TREB", treble_max)]
  sb.write_string("\u001b[90m      \u001b[0m")
  for band_idx in 0..<3 {
    let (label, max_val) = bands[band_idx]
    sb.write_string("\u001b[90m\{label} \u001b[0m")
    let level = if frame_max > 1.0e-6 {
      let ratio = max_val / frame_max
      if ratio > 1.0e-6 {
        // 40 dB display window: strongest band = 10 cells, -40 dB = 0 cells
        let db = 20.0 * @math.log10(ratio)
        ((db + 40.0) / 40.0 * 10.0).to_int().clamp(min=0, max=10)
      } else {
        0
      }
    } else {
      0
    }
    for i in 0..<10 {
      if i < level {
        let color_idx = (i.to_double() / 9.0 * 9.0).to_int().clamp(min=0, max=9)
        sb.write_string(band_colors.unsafe_get(color_idx))
        sb.write_string("\u{2588}")
      } else {
        sb.write_string("\u001b[90m\u{2591}\u001b[0m")
      }
    }
    sb.write_string(" ")
  }
  sb.write_string("\n")
}

///|
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
  let bin_starts = Array::make(num_bars, 0)
  let bin_ends = Array::make(num_bars, 0)
  for bar in 0..<num_bars {
    bin_starts[bar] = bin_map[bar]
    if bar < num_bars - 1 {
      bin_ends[bar] = bin_map[bar + 1] + 1
    } else {
      bin_ends[bar] = half_fft
    }
    if bin_ends[bar] <= bin_starts[bar] {
      bin_ends[bar] = bin_starts[bar] + 1
    }
    if bin_ends[bar] > half_fft {
      bin_ends[bar] = half_fft
    }
  }
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
  let (bar_hues, bar_sats, bar_lights) = precompute_bar_colors(num_bars)
  let color_tables = precompute_color_tables(
    bar_hues, bar_sats, bar_lights, num_bars, 40, 3.0,
  )
  // Precompute stable frequency-label colors. Unlike the bars these do NOT
  // rotate with the rainbow: a coordinate axis should stay colour-stable so
  // the labels remain readable while the spectrum animates.
  let label_colors = Array::make(num_bars, "")
  for bar in 0..<num_bars {
    let (r, g, b) = hsl_to_rgb(bar_hues[bar], 0.40, 0.62)
    label_colors[bar] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Row contribution: range [3.0, 17.0] for 32 brightness levels
  // Bottom rows dimmer, top rows brighter — 3D glow effect
  let row_contrib = Array::makei(max_height, fn(row) {
    3.0 + row.to_double() / max_height.to_double() * 14.0
  })
  let max_levels = max_height * sub_res
  let height_factor = 14.0 / max_levels.to_double()
  // Precompute RMS meter colors (green→yellow→red gradient, 20 levels)
  let meter_width = 20
  let meter_colors = Array::make(meter_width, "")
  for i in 0..<meter_width {
    let pct = i.to_double() / meter_width.to_double()
    let hue = 120.0 * (1.0 - pct)
    let (r, g, b) = hsl_to_rgb(hue, 0.85, 0.55)
    meter_colors[i] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Precompute progress-bar colors: a cool cyan→violet ramp along the bar.
  // Deliberately different from the spectrum rainbow so the progress reads as a
  // UI element rather than another miniature spectrum.
  let progress_colors = Array::make(num_bars, "")
  for i in 0..<num_bars {
    let ratio = i.to_double() / (num_bars - 1).to_double()
    let (r, g, b) = hsl_to_rgb(190.0 + ratio * 95.0, 0.75, 0.60)
    progress_colors[i] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Precompute frequency label strings — eliminates per-frame nested loop
  // and format_freq calls. label_strings[bar] holds PLAIN text only: ANSI
  // codes must never be stored here because their length would be mistaken
  // for display width when positioning the next label (which glued all
  // labels together into "50Hz100Hz200Hz...").
  let label_strings = Array::make(num_bars, "")
  for j in 0..<grid_bars.length() {
    let gb = grid_bars[j]
    if gb >= 0 && gb < num_bars {
      let hz = freq_labels[j]
      label_strings[gb] = if hz >= 1000 { "\{hz / 1000}kHz" } else { "\{hz}Hz" }
    }
  }
  // Precompute dB scale labels — eliminates per-frame hsl_to_rgb calls.
  // Labels are all exactly 5 columns wide so every spectrum row starts at the
  // same left column (a width mismatch used to shift -12dB rows by 1 column).
  // Each tick is emitted only once (a naive row*5/height repeats ticks,
  // producing e.g. three identical "0dB" labels in a 12-row display).
  let db_scale_labels = Array::make(max_height, "")
  let labels = ["  0dB", " -6dB", "-12dB", "-18dB", "-24dB"]
  let mut prev_label_row = -1
  for row in 0..<max_height {
    let label_row = row * 5 / max_height
    if label_row < 5 && label_row != prev_label_row {
      prev_label_row = label_row
      // Single cool hue, dimming with depth, so the dB scale reads as a calm
      // instrument axis instead of five unrelated colors.
      let light = 0.64 - label_row.to_double() * 0.06
      let (r, g, b) = hsl_to_rgb(228.0, 0.28, light)
      db_scale_labels[row] = "\u001b[38;2;\{r};\{g};\{b}m" +
        labels[label_row] +
        ansi_reset +
        " "
    } else {
      db_scale_labels[row] = "\u001b[38;2;70;70;90m│    \u001b[0m "
    }
  }
  // Precompute waveform color table — 9 scaled values × 256 amplitude levels
  // Index: (scaled + 4) * 256 + amp_int. Eliminates per-frame string interpolation.
  // Beat cases (scaled 3|4, -3|-4) store non-beat colors; beat override is rare.
  let wf_tbl = Array::make(9 * 256, "")
  for amp in 0..<256 {
    // scaled 0: fixed dim color
    wf_tbl[4 * 256 + amp] = "\u001b[38;2;88;98;124m─\u001b[0m"
    // scaled 1: g = 180 + amp/4
    let g1 = 180 + amp / 4
    wf_tbl[5 * 256 + amp] = "\u001b[38;2;80;\{g1};200m▔\u001b[0m"
    // scaled 2: g = 200 + amp/5
    let g2 = 200 + amp / 5
    wf_tbl[6 * 256 + amp] = "\u001b[38;2;60;\{g2};180m▀\u001b[0m"
    // scaled 3|4 non-beat: g = 220 + amp/6
    let g3 = 220 + amp / 6
    wf_tbl[7 * 256 + amp] = "\u001b[38;2;100;\{g3};120m█\u001b[0m"
    wf_tbl[8 * 256 + amp] = wf_tbl[7 * 256 + amp]
    // scaled -1: b = 180 + amp/4
    let b1 = 180 + amp / 4
    wf_tbl[3 * 256 + amp] = "\u001b[38;2;80;150;\{b1}m▁\u001b[0m"
    // scaled -2: b = 200 + amp/5
    let b2 = 200 + amp / 5
    wf_tbl[2 * 256 + amp] = "\u001b[38;2;100;120;\{b2}m▄\u001b[0m"
    // scaled -3|-4 non-beat: b = 220 + amp/6
    let b3 = 220 + amp / 6
    wf_tbl[1 * 256 + amp] = "\u001b[38;2;120;150;\{b3}m█\u001b[0m"
    wf_tbl[0 * 256 + amp] = wf_tbl[1 * 256 + amp]
  }
  // Precompute bar offsets — eliminates per-frame Array::makei allocation
  let pre_bar_offsets = Array::makei(num_bars, fn(bar) {
    bar * num_brightness_levels
  })
  // Precompute spectrogram waterfall background tables (per-bar hue, rotating)
  let spectro_bg_tables = precompute_spectro_bg_tables(
    bar_hues, bar_sats, bar_lights, num_bars, 40, 3.0,
  )
  // Precompute band meter colors (green→yellow→red, 10 levels)
  let band_cols = Array::make(10, "")
  for i in 0..<10 {
    let pct = i.to_double() / 9.0
    let hue = 120.0 * (1.0 - pct)
    let (r, g, b) = hsl_to_rgb(hue, 0.85, 0.55)
    band_cols[i] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Initialize spectrogram history (3 rows × num_bars)
  let spectro_hist = Array::makei(3, fn(_) { Array::make(num_bars, 0) })
  DisplayContext::{
    num_bars,
    max_height,
    sub_res,
    max_levels,
    bin_map,
    bin_starts,
    bin_ends,
    is_grid,
    color_tables,
    color_table_idx: 0,
    row_contrib,
    height_factor,
    sample_rate,
    fft_size,
    meter_colors,
    label_strings,
    label_colors,
    db_scale_labels,
    waveform_colors: wf_tbl,
    bar_offsets: pre_bar_offsets,
    heights_d: Array::make(num_bars, 0.0),
    peak_heights_d: Array::make(num_bars, 0.0),
    spectrogram_history: spectro_hist,
    spectrogram_idx: 0,
    spectrogram_bg_tables: spectro_bg_tables,
    auto_gain: 1.0,
    band_colors: band_cols,
    progress_colors,
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
    // Power curve: boosts low/mid values for better detail visibility
    @math.pow(mag, 0.6).clamp(min=0.0, max=1.0)
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
fn is_ref_line(row : Int32, max_height : Int32) -> Bool {
  row == 1 * max_height / 4
}

///|
/// Render waveform strip with true-color amplitude-based coloring.
fn render_waveform(
  sb : StringBuilder,
  waveform : Array[Double],
  width : Int32,
  pulse : Double,
  wf_colors : Array[String],
) -> Unit {
  sb.write_string("\u001b[90m   WV \u001b[0m")
  let n = waveform.length()
  if n == 0 {
    sb.write_string("\n")
    return
  }
  let step = n.to_double() / width.to_double()
  let has_beat = pulse > 0.3
  for i in 0..<width {
    let sample_idx = (i.to_double() * step).to_int().clamp(min=0, max=n - 1)
    let sample = waveform[sample_idx]
    let scaled = (sample * 4.0).clamp(min=-4.0, max=4.0).to_int()
    let abs_amp = sample.abs().clamp(min=0.0, max=1.0)
    let amp_int = (abs_amp * 255.0).to_int().clamp(min=0, max=255)
    // Precomputed table: index = (scaled + 4) * 256 + amp_int
    let tbl_idx = (scaled + 4) * 256 + amp_int
    // Beat override for high-amplitude bars (rare path)
    if has_beat && (scaled >= 3 || scaled <= -3) {
      if scaled >= 3 {
        let r = 200 + (pulse * 55.0).to_int()
        sb.write_string("\u001b[38;2;\{r};255;100m█\u001b[0m")
      } else {
        let r = 100 + (pulse * 155.0).to_int()
        sb.write_string("\u001b[38;2;\{r};150;255m█\u001b[0m")
      }
    } else {
      sb.write_string(wf_colors.unsafe_get(tbl_idx))
    }
  }
  sb.write_string("\n")
}

///|
/// Main spectrum renderer — fully optimized hot path.
/// All arrays reused, color lookup via precomputed table, O(1) brightness.
fn render_spectrum(
  magnitudes : Array[Double],
  ctx : DisplayContext,
  peak_heights : Array[Int32],
  peak_frames : Array[Int32],
  prev_heights : Array[Int32],
  render_prev : Array[Double],
  heights : Array[Int32],
  current_pos : Int32,
  total_samples : Int32,
  rms_value : Double,
  beat_intensity : Double,
  waveform : Array[Double],
  total_time_str : String,
  dom_bar : Int32,
  bpm : Double,
  beat_pulse : Double,
  beat_count : Int32,
) -> String {
  let sb = StringBuilder::StringBuilder()
  let num_bars = ctx.num_bars
  let max_height = ctx.max_height
  let sub_res = ctx.sub_res
  let max_levels = ctx.max_levels
  let sample_rate = ctx.sample_rate
  let fft_size = ctx.fft_size

  sb.write_string(ansi_clear)

  // --- Auto-gain control: adjust sensitivity based on current max magnitude ---
  // Track rolling max and adjust gain so bars fill ~70% of max_height
  let mut frame_max = 0.0
  for bar in 0..<num_bars {
    let m = magnitudes.unsafe_get(bar)
    if m > frame_max {
      frame_max = m
    }
  }
  // Target: frame_max * auto_gain ≈ 0.7 (after scale_magnitude)
  // Adjust gain slowly toward target
  if frame_max > 0.001 {
    let target_gain = 0.7 / frame_max
    // Slow adaptation: 90% old + 10% new, clamped to [0.3, 5.0]
    ctx.auto_gain = (ctx.auto_gain * 0.9 + target_gain * 0.1).clamp(
      min=0.3,
      max=5.0,
    )
  }
  let ag = ctx.auto_gain

  // --- Fused pass 1: height calc + attack/release envelope ---
  // dominant_bar (dom_bar) is passed in with sticky logic from main.mbt
  for bar in 0..<num_bars {
    let mag = magnitudes.unsafe_get(bar) * ag
    let raw_height = (scale_magnitude(mag) * max_levels.to_double()).to_int()
    // Attack/release envelope (inline — saves one loop over num_bars)
    // Less aggressive attack (0.5/0.5) reduces rise-time flicker
    let prev = prev_heights[bar].to_double()
    let curr = raw_height.to_double()
    let smoothed = if curr >= prev {
      prev * 0.5 + curr * 0.5
    } else {
      prev * 0.82 + curr * 0.18
    }
    // Round instead of truncate — eliminates integer-boundary oscillation
    heights[bar] = (smoothed + 0.5).to_int()
    prev_heights[bar] = heights[bar]
  }

  // --- Fused pass 2: spatial smoothing + peak hold update ---
  let mut prev_val = 0.0
  for bar in 0..<num_bars {
    let left = prev_val
    let center = heights[bar].to_double()
    let right = if bar < num_bars - 1 {
      heights[bar + 1].to_double()
    } else {
      0.0
    }
    // Stronger spatial smoothing (0.3/0.4/0.3) suppresses inter-bar flicker
    let blurred = left * 0.3 + center * 0.4 + right * 0.3
    prev_val = center
    // Temporal IIR on doubles — the key anti-flicker measure.
    // Operating on doubles (not ints) is critical: an int IIR cannot
    // eliminate ±1 oscillation (e.g. 15↔16), but a double IIR smooths
    // the value to ~15.4 which quantizes stably to 15.
    let iir_val = render_prev.unsafe_get(bar) * 0.4 + blurred * 0.6
    render_prev.unsafe_set(bar, iir_val)
    heights[bar] = (iir_val + 0.5).to_int()
    // Peak hold update (inline — saves one loop over num_bars)
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

  // --- Update spectrogram waterfall history ---
  // Copy current heights into the next history slot
  let spectro_idx = ctx.spectrogram_idx
  let spectro_row = ctx.spectrogram_history.unsafe_get(spectro_idx)
  for bar in 0..<num_bars {
    spectro_row.unsafe_set(bar, heights[bar])
  }
  ctx.spectrogram_idx = (spectro_idx + 1) % 3

  // --- Dominant frequency + note ---
  let dominant_bin = ctx.bin_map[dom_bar]
  let dominant_freq = dominant_bin.to_double() *
    sample_rate.to_double() /
    fft_size.to_double()
  let dominant_freq_int = dominant_freq.to_int()
  let note_name = freq_to_note(dominant_freq_int)

  // --- Beat glow border with flash effect ---
  // Driven by the FAST beat_pulse (×0.85/frame), not the slow beat_intensity
  // (×0.92/frame). At ~120 BPM the slow value never fell back below the warm
  // threshold before the next beat, so the border sat permanently warm and the
  // flash vanished. The pulse returns to calm between beats, so each hit reads
  // as a real flash: bright white on the hit, warm decay, then soft cyan.
  let flash = beat_pulse
  let beat_glow = if flash > 0.6 {
    // Flash: bright white-yellow on strong beats
    "\u001b[1;38;2;255;255;\{(180 + (flash * 75.0).to_int())}m"
  } else if flash > 0.3 {
    "\u001b[38;2;255;\{(60.0 + flash * 170.0).to_int()};\{(30.0 + flash * 90.0).to_int()}m"
  } else {
    "\u001b[38;2;90;200;230m"
  }
  // Beat pulse: scale border thickness character on strong beats
  let border_char = if flash > 0.5 { "━" } else { "═" }

  // --- Beat-reactive brightness boost ---
  // Fast pulse gives a snappy brightness hit on each beat; the slow intensity
  // keeps a gentle sustained bloom. Together they read as punch + afterglow.
  let beat_boost = (beat_intensity * 4.0 + beat_pulse * 8.0).to_int()
  // Scanline: a gentle highlight row that sweeps up and down.
  // Advance one row per frame (pos rises by fft_size/2 each frame); the old
  // `current_pos / sub_res` stepped 64 rows per frame, i.e. it looked random.
  let scan_cycle = max_height * 2
  let scan_raw = current_pos / (fft_size / 2) % scan_cycle
  let scan_row = if scan_raw < max_height {
    scan_raw
  } else {
    scan_cycle - scan_raw - 1
  }

  // --- Header ---
  // Inner width matches the spectrum area: 6-col left gutter + num_bars columns
  let header_width = num_bars + 6
  let text_width = header_width - 2
  let title = truncate_to_width(
    "🎵 MoonFFTmusic — Real-time Spectrum Analyzer", text_width,
  )
  let beat_indicator = if beat_pulse > 0.5 { " ♫" } else { "  " }
  let bpm_str = if bpm > 0.0 { " | \{bpm.to_int()} BPM" } else { "" }
  let info_line = truncate_to_width(
    "\{sample_rate}Hz | FFT \{fft_size} | Peak \{format_freq(dominant_freq_int)} (\{note_name})\{beat_indicator}\{bpm_str} | \{format_time(current_pos, sample_rate)}",
    text_width,
  )

  sb.write_string(beat_glow)
  sb.write_string("╔")
  for _ in 0..<header_width {
    sb.write_string(border_char)
  }
  sb.write_string("╗\n║ ")
  sb.write_string(title)
  let title_pad = (text_width - display_width(title)).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<title_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n║ ")
  sb.write_string(info_line)
  let info_pad = (text_width - display_width(info_line)).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<info_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n╚")
  for _ in 0..<header_width {
    sb.write_string(border_char)
  }
  sb.write_string("╝\n\u001b[0m")

  // --- Hoist loop-invariant values for all rendering sections below ---
  let height_factor = ctx.height_factor
  let nbl_minus_1 = num_brightness_levels - 1
  let color_tbl = ctx.color_tables.unsafe_get(ctx.color_table_idx)
  // Precompute bar * nbl offsets once (avoids multiplication per bar per row)
  let bar_offsets = ctx.bar_offsets

  // --- Peak marker row with bar top connectors (MoonBit `match` dispatch) ---
  sb.write_string("\u001b[90m      \u001b[0m")
  for bar in 0..<num_bars {
    if bar == dom_bar && heights[bar] > 0 {
      sb.write_string("\u001b[1;33m▼\u001b[0m")
    } else if heights[bar] > 0 {
      // Bar top connector — use blended height for temporal stability
      // Blending pass-1 (prev_heights) and pass-2 (heights) smooths
      // the connector input, reducing ╱↔─↔╲ oscillation.
      let blend_h = (heights[bar] + prev_heights[bar]) / 2
      let left_h = if bar > 0 {
        (heights[bar - 1] + prev_heights[bar - 1]) / 2
      } else {
        0
      }
      let right_h = if bar < num_bars - 1 {
        (heights[bar + 1] + prev_heights[bar + 1]) / 2
      } else {
        0
      }
      // Connector line sits on the bar-top envelope. Raised brightness floor
      // (+16, min 10) keeps the ridge visible even for short/quiet bars —
      // previously it rendered near-black and effectively disappeared.
      let level = (heights[bar].to_double() * height_factor + 16.0)
        .to_int()
        .clamp(min=10, max=nbl_minus_1)
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level))
      sb.write_string(connector_char(left_h, blend_h, right_h))
    } else if ctx.is_grid[bar] {
      sb.write_string("\u001b[38;2;58;72;104m")
      sb.write_string("╎\u001b[0m")
    } else {
      sb.write_string(" ")
    }
  }
  sb.write_string("\n")

  // --- Piano keyboard row — shows detected note on 2-octave keyboard ---
  let dom_midi = if dominant_freq > 0 {
    (69.0 + 12.0 * @math.log2(dominant_freq / 440.0))
    .round()
    .to_int()
    .clamp(min=48, max=71)
  } else {
    -1
  }
  render_piano_keyboard(sb, dom_midi, beat_pulse, beat_count)

  // --- Render bars with precomputed color table (continuous, no gaps) ---
  // Precompute heights[bar] * height_factor once — avoids to_double + multiply
  // per bar per row (saves 2 ops × 60 bars × 20 rows = 2400 ops/frame)
  let heights_d = ctx.heights_d
  let peak_heights_d = ctx.peak_heights_d
  for bar in 0..<num_bars {
    heights_d.unsafe_set(bar, heights[bar].to_double() * height_factor)
    peak_heights_d.unsafe_set(
      bar,
      peak_heights[bar].to_double() * height_factor,
    )
  }
  for row in 0..<max_height {
    sb.write_string(ctx.db_scale_labels.unsafe_get(row))
    let level_top = (max_height - row) * sub_res
    let level_bottom = (max_height - row - 1) * sub_res
    let ref_line = is_ref_line(row, max_height)
    // Row-invariant base: row_contrib[row] + beat_boost + scanline
    // Scanline adds a subtle +2 brightness to one sweeping row
    let scan_boost = if row == scan_row { 2.0 } else { 0.0 }
    let row_base = ctx.row_contrib[row] + beat_boost.to_double() + scan_boost
    for bar in 0..<num_bars {
      let bar_off = bar_offsets.unsafe_get(bar)
      match
        bar_state(heights[bar], peak_heights[bar], level_top, level_bottom) {
        FullBlock => {
          // Spotlight: dominant bar + neighbors get extra brightness on beats
          let dom_boost = if beat_pulse > 0.2 {
            let dist = (bar - dom_bar).abs()
            if dist == 0 {
              beat_pulse * 6.0
            } else if dist == 1 {
              beat_pulse * 2.5
            } else {
              0.0
            }
          } else {
            0.0
          }
          let level = (row_base + heights_d.unsafe_get(bar) + dom_boost)
            .to_int()
            .clamp(min=0, max=nbl_minus_1)
          sb.write_string(color_tbl.unsafe_get(bar_off + level))
          sb.write_string("█")
        }
        BarCap => {
          // Crown: extra brightness on bar top — glowing cap effect
          let level = (row_base + heights_d.unsafe_get(bar) + 8.0)
            .to_int()
            .clamp(min=0, max=nbl_minus_1)
          sb.write_string(color_tbl.unsafe_get(bar_off + level))
          sb.write_string("▀")
        }
        PartialBlock(frac) => {
          let level = (row_base + heights_d.unsafe_get(bar))
            .to_int()
            .clamp(min=0, max=nbl_minus_1)
          sb.write_string(color_tbl.unsafe_get(bar_off + level))
          sb.write_string(partial_blocks[frac])
        }
        PeakMarker => {
          sb.write_string("\u001b[1m")
          let peak_level = (peak_heights_d.unsafe_get(bar) + 20.0)
            .to_int()
            .clamp(min=10, max=nbl_minus_1)
          sb.write_string(color_tbl.unsafe_get(bar_off + peak_level))
          sb.write_string("━")
          sb.write_string("\u001b[22m")
        }
        Empty =>
          if ctx.is_grid[bar] {
            sb.write_string("\u001b[38;2;58;72;104m")
            sb.write_string("╎\u001b[0m")
          } else if ref_line {
            sb.write_string("\u001b[38;2;72;84;116m")
            sb.write_string("┄\u001b[0m")
          } else {
            sb.write_string(" ")
          }
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Spectrogram waterfall: 3 rows of recent spectrum history ---
  // Each row shows a previous frame; hue = frequency (matches the bars),
  // brightness = intensity. Row 0 = most recent, Row 2 = oldest.
  let spectro_hist = ctx.spectrogram_history
  let spectro_idx = ctx.spectrogram_idx
  let spectro_tbl = ctx.spectrogram_bg_tables.unsafe_get(ctx.color_table_idx)
  for row in 0..<3 {
    sb.write_string("\u001b[90m      \u001b[0m")
    // Get the historical frame: row 0 = most recent (current frame - 1)
    // row 1 = 2 frames ago, row 2 = 3 frames ago
    let hist_idx = (spectro_idx - 1 - row + 3) % 3
    let hist_row = spectro_hist.unsafe_get(hist_idx)
    for bar in 0..<num_bars {
      let h = hist_row.unsafe_get(bar)
      if h > 0 {
        let level = (h.to_double() * height_factor + 3.0)
          .to_int()
          .clamp(min=0, max=nbl_minus_1)
        sb.write_string(
          spectro_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level),
        )
      } else {
        sb.write_string(" ")
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Frequency labels (precomputed text) ---
  sb.write_string("      ")
  let mut label_pos = 0
  for i in 0..<num_bars {
    let label = ctx.label_strings.unsafe_get(i)
    if label.length() > 0 {
      if label_pos < i {
        // Align the label with its bar / grid line
        while label_pos < i {
          sb.write_string(" ")
          label_pos = label_pos + 1
        }
      } else {
        // Previous label already covered this bar — keep a separating space
        sb.write_string(" ")
        label_pos = label_pos + 1
      }
      sb.write_string(ctx.label_colors.unsafe_get(i))
      sb.write_string(label)
      sb.write_string(ansi_reset)
      label_pos = label_pos + label.length()
    }
  }
  sb.write_string("\n")

  // --- Waveform strip ---
  render_waveform(sb, waveform, num_bars, beat_pulse, ctx.waveform_colors)

  // --- Energy history sparkline (MoonBit `mut` circular buffer) ---
  render_band_meters(sb, magnitudes, num_bars, ctx.band_colors)

  // --- RMS meter ---
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
  let meter_filled = (rms_pct * 20.0).to_int()

  let meter_width = 20
  // RMS meter with beat-reactive glow
  let rms_glow = if beat_pulse > 0.5 { "\u001b[1;33m" } else { "\u001b[1;37m" }
  sb.write_string("      ")
  sb.write_string(rms_glow)
  sb.write_string("RMS: \u001b[0m[")
  for i in 0..<meter_width {
    if i < meter_filled {
      sb.write_string(ctx.meter_colors.unsafe_get(i))
      sb.write_string("█")
    } else {
      sb.write_string("\u001b[90m░")
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

  // Progress bar with beat-reactive pulse (bold on beat hits)
  let prog_glow = if beat_pulse > 0.3 { "\u001b[1m" } else { "" }
  for i in 0..<num_bars {
    if i < progress_filled {
      sb.write_string(prog_glow)
      sb.write_string(ctx.progress_colors.unsafe_get(i))
      sb.write_string("║")
    } else if i == progress_filled {
      sb.write_string(prog_glow)
      sb.write_string(ctx.progress_colors.unsafe_get(i))
      sb.write_string("▓")
    } else {
      sb.write_string("\u001b[90m░")
    }
  }
  sb.write_string("\u001b[0m ")
  let pct_int = (progress_pct * 100.0).to_int()
  sb.write_string(
    "\{pct_int}%  \{format_time(current_pos, sample_rate)} / \{total_time_str}",
  )

  sb.to_string()
}
