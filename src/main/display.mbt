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
/// Cells per BASS/MID/TREB meter. Chosen so that
/// `6 (dB gutter) + 3 × (5 label + 14 cells + 1 space) = 66` display columns,
/// matching the spectrum body width exactly.
let band_meter_cells : Int32 = 14

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
  // Tables to rotate through: 40 for rainbow, 1 for fire/ice (no rotation)
  num_color_tables : Int32
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
  // Precomputed spectrum baseline (L-shaped axis corner + filler dashes, 66 cols)
  spectrum_baseline : String
  // Small-terminal layout: piano keyboard and band meters are dropped when the
  // terminal is too short to fit the full frame (see main.mbt overhead calc).
  show_piano : Bool
  show_bands : Bool
  // Active palette (0 rainbow / 1 fire / 2 ice) — drives scheme-aware accents
  // (beat border calm colour, waveform amplitude ramp).
  scheme : Int32
  // Waveform amplitude colors (256 levels, dim gray-blue → bright cyan)
  wave_amp_colors : Array[String]
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
  // Smoothed band meter levels (0..10 dB scale, IIR across frames)
  band_levels : Array[Double]
  // Band meter ranges in bar indices — perceptual split
  // (BASS 20-250Hz, MID 250-2kHz, TREB 2kHz+)
  band_starts : Array[Int32]
  band_ends : Array[Int32]
  // Smoothed RMS level in dB (IIR across frames, starts at meter floor)
  mut rms_level : Double
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
/// Uses MoonBit `match` for character selection: ─ ╱ ╲ ∧ ∨
fn connector_char(left_h : Int32, curr_h : Int32, right_h : Int32) -> String {
  let diff_r = right_h - curr_h
  let diff_l = curr_h - left_h
  // Threshold=6 creates a wider dead zone, preventing ╱↔─↔╲ flicker
  // when neighboring bar heights oscillate within a small range.
  match (diff_l, diff_r) {
    (dl, dr) if dl > 6 && dr > 6 => "╱" // rising →
    (dl, dr) if dl < -6 && dr < -6 => "╲" // falling →
    // Peak and valley used to share "╳", so the contour did not read as an
    // envelope. ∧ sits above and ∨ below, making the shape unambiguous.
    (dl, dr) if dl > 6 && dr < -6 => "∧" // peak
    (dl, dr) if dl < -6 && dr > 6 => "∨" // valley
    _ => "─" // similar height — flat connector
  }
}

///|
enum BarState {
  FullBlock
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
/// Precompute color tables. `scheme` selects the palette semantics:
///   0 rainbow — hue anchored to frequency (per-bar hue ± 18° vertical
///               gradient), `num_tables` tables rotate the hue 3°/step
///   1 fire    — hue painted by HEIGHT: red base → yellow crest (cava style)
///   2 ice     — violet base → cyan crest
/// fire/ice ignore hue rotation, so callers pass num_tables = 1 for them.
fn precompute_color_tables(
  bar_hues : Array[Double],
  bar_sats : Array[Double],
  bar_lights : Array[Double],
  num_bars : Int32,
  num_tables : Int32,
  hue_step : Double,
  scheme : Int32,
) -> Array[Array[String]] {
  let nbl = num_brightness_levels
  let tables = Array::make(num_tables, Array::make(0, ""))
  for tbl_idx in 0..<num_tables {
    let hue_offset = tbl_idx.to_double() * hue_step
    let table = Array::make(num_bars * nbl, "")
    for bar in 0..<num_bars {
      let hue = bar_hues[bar] + hue_offset
      let (sat, light) = match scheme {
        0 => (bar_sats[bar], bar_lights[bar])
        1 => (0.95, 0.52)
        _ => (0.75, 0.55)
      }
      // Vertical hue gradient. rainbow: a deeper hue at the base, a brighter
      // hue at the top (±18°) — colour still means frequency. fire/ice: every
      // column shares one hue ramp from base to crest — colour means loudness.
      let hue0 = match scheme {
        0 => hue - 18.0
        1 => 8.0
        _ => 250.0
      }
      let hue1 = match scheme {
        0 => hue + 18.0
        1 => 60.0
        _ => 195.0
      }
      let (br0, bg0, bb0) = hsl_to_rgb(hue0, sat, light)
      let (br1, bg1, bb1) = hsl_to_rgb(hue1, sat, light)
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
/// Map perceptual frequency band boundaries to bar index ranges.
/// BASS = 20-250Hz, MID = 250-2kHz, TREB = 2kHz+ (bars are log-spaced, so a
/// fixed bar-count split puts most of the audible bass inside "MID").
fn band_bar_ranges(
  num_bars : Int32,
  half_fft : Int32,
  sample_rate : Int32,
) -> (Array[Int32], Array[Int32]) {
  let mut bass_end = freq_to_bar(250.0, num_bars, half_fft, sample_rate)
  let mut mid_end = freq_to_bar(2000.0, num_bars, half_fft, sample_rate)
  // Defensive monotonicity for extreme mappings (tiny displays, low rates)
  if bass_end < 1 {
    bass_end = 1
  }
  if bass_end > num_bars - 2 {
    bass_end = num_bars - 2
  }
  if mid_end > num_bars - 1 {
    mid_end = num_bars - 1
  }
  if mid_end <= bass_end {
    mid_end = bass_end + 1
  }
  ([0, bass_end, mid_end], [bass_end, mid_end, num_bars])
}

///|
/// Band meter level in 0..10 cells on an absolute dB scale.
/// Full scale = fft_size/4: a unit-amplitude sine yields that magnitude
/// through a Hann window. Display window is -60..0 dB, matching the RMS bar.
fn band_level_db(max_val : Double, fft_size : Int32) -> Int32 {
  if fft_size <= 0 || max_val <= 0.0 {
    return 0
  }
  let db = 20.0 * @math.log10(max_val / (fft_size.to_double() / 4.0))
  ((db + 60.0) / 60.0 * 10.0).to_int().clamp(min=0, max=10)
}

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
  scheme : Int32,
) -> Array[Array[String]] {
  let nbl = num_brightness_levels
  let tables = Array::make(num_tables, Array::make(0, ""))
  for tbl_idx in 0..<num_tables {
    let hue_offset = tbl_idx.to_double() * hue_step
    let table = Array::make(num_bars * nbl, "")
    for bar in 0..<num_bars {
      let hue = bar_hues[bar] + hue_offset
      let (sat, light) = match scheme {
        0 => (bar_sats[bar], bar_lights[bar])
        1 => (0.95, 0.52)
        _ => (0.75, 0.55)
      }
      // Same vertical hue gradient as the live bars, so a column keeps a
      // continuous colour from the spectrum down through the history rows.
      let hue0 = match scheme {
        0 => hue - 18.0
        1 => 8.0
        _ => 250.0
      }
      let hue1 = match scheme {
        0 => hue + 18.0
        1 => 60.0
        _ => 195.0
      }
      let (br0, bg0, bb0) = hsl_to_rgb(hue0, sat, light)
      let (br1, bg1, bb1) = hsl_to_rgb(hue1, sat, light)
      let bar_off = bar * nbl
      for level in 0..<nbl {
        let lr = level.to_double() / (nbl - 1).to_double()
        // History stays dimmer than the live bars, but the old range
        // (0.15..0.81) rendered short history cells at RGB ≈ 40 luminance —
        // effectively invisible on a dark terminal. This range lifts the
        // floor while keeping the same hue and the "recedes" ordering.
        let brightness = 0.24 + lr * 0.82
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
/// Render piano keyboard — 2 octaves (24 semitones) from C3 (MIDI 48).
/// The strip is horizontally centred in the `width`-column body so it no
/// longer hugs the left edge and leaves a large empty gap on the right.
fn render_piano_keyboard(
  sb : StringBuilder,
  width : Int32,
  dom_midi : Int32,
  beat_pulse : Double,
  beat_count : Int32,
) -> Unit {
  // 2 octaves starting from MIDI 48 (C3)
  let start_midi = 48
  let num_keys = 24
  // emoji(2) + space + keys + " C3-C5"(6) + " ♡"(2) + optional rhythm(6)
  let mut content_width = 2 + 1 + num_keys + 6 + 2
  if beat_count > 0 {
    content_width = content_width + 6
  }
  let pad_left = ((width - content_width) / 2).clamp(min=0, max=width)
  let pad_right = (width - content_width - pad_left).clamp(min=0, max=width)
  // Keep the left axis continuous through the keyboard row as well.
  sb.write_string("\u001b[38;2;70;70;90m│     \u001b[0m")
  for _ in 0..<pad_left {
    sb.write_string(" ")
  }
  sb.write_string("\u001b[35m\u{1F3B9}\u001b[0m ")
  for i in 0..<num_keys {
    let midi = start_midi + i
    let is_black = piano_key_is_black(i)
    if midi == dom_midi {
      // Detected note — solid yellow bar keeps the key shape readable
      // (the old ▼ glyph replaced a key and broke the keyboard pattern).
      sb.write_string("\u001b[1;33m\u{25AE}\u001b[0m")
    } else if is_black {
      // Black key — thin left-edge block reads as the narrower key,
      // instead of every key looking like the same "│" stick.
      sb.write_string("\u001b[38;2;120;90;155m\u{258F}\u001b[0m")
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
  for _ in 0..<pad_right {
    sb.write_string(" ")
  }
  sb.write_string("\n")
}

///|
/// Render frequency band meters — BASS / MID / TREBLE energy levels.
/// Ranges follow perceptual frequency splits (precomputed bar indices) and
/// each meter shows the band's absolute loudness on a -60..0 dB window, so
/// the meters agree with the spectrum instead of just ranking bands.
fn render_band_meters(
  sb : StringBuilder,
  magnitudes : Array[Double],
  band_starts : Array[Int32],
  band_ends : Array[Int32],
  fft_size : Int32,
  band_colors : Array[String],
  band_levels : Array[Double],
) -> Unit {
  // Per-band peak magnitude over its frequency range.
  // Labels are padded to a fixed 5 columns so BASS/MID/TREB meters line up.
  let bands = [
    ("BASS ", band_starts.unsafe_get(0), band_ends.unsafe_get(0)),
    ("MID  ", band_starts.unsafe_get(1), band_ends.unsafe_get(1)),
    ("TREB ", band_starts.unsafe_get(2), band_ends.unsafe_get(2)),
  ]
  // Left gutter matches the 6-column dB scale, so all status rows start at
  // the same column as the spectrum body.
  sb.write_string("\u001b[90m      \u001b[0m")
  for idx in 0..<3 {
    let (label, start, end) = bands[idx]
    let mut max_val = 0.0
    for i in start..<end {
      let m = magnitudes.unsafe_get(i)
      if m > max_val {
        max_val = m
      }
    }
    sb.write_string("\u001b[90m\{label}\u001b[0m")
    // IIR smoothing (fast attack / slow release) so the meters move like
    // needle VU meters instead of jumping cell-to-cell with the raw frame.
    let raw = band_level_db(max_val, fft_size).to_double()
    let prev = band_levels.unsafe_get(idx)
    let smoothed = if raw >= prev {
      prev * 0.55 + raw * 0.45
    } else {
      prev * 0.85 + raw * 0.15
    }
    band_levels.unsafe_set(idx, smoothed)
    // 0..10 dB scale stretched across 14 cells, rounded.
    let filled = (smoothed * band_meter_cells.to_double() / 10.0 + 0.5)
      .to_int()
      .clamp(min=0, max=band_meter_cells)
    for i in 0..<band_meter_cells {
      if i < filled {
        let color_idx = (i.to_double() /
          (band_meter_cells - 1).to_double() *
          (band_meter_cells - 1).to_double())
          .to_int()
          .clamp(min=0, max=band_meter_cells - 1)
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
test "band_bar_ranges splits bars at frequency boundaries" {
  // Default mapping: 60 bars over 512 bins @ 44.1kHz — 250Hz ≈ bar 16,
  // 2kHz ≈ bar 36, so the audible bass no longer lands inside "MID".
  let (starts, ends) = band_bar_ranges(60, 512, 44100)
  assert_eq(starts[0], 0)
  assert_eq(ends[0], 16)
  assert_eq(starts[1], 16)
  assert_eq(ends[1], 36)
  assert_eq(starts[2], 36)
  assert_eq(ends[2], 60)
}

///|
test "band_bar_ranges stays monotonic on tiny displays" {
  let (starts, ends) = band_bar_ranges(8, 4, 8000)
  assert_eq(starts[0], 0)
  assert_true(ends[0] > starts[0])
  assert_true(ends[1] > ends[0])
  assert_true(ends[2] > ends[1])
  assert_eq(ends[2], 8)
}

///|
test "band_level_db maps magnitude onto 10-cell window" {
  // fft_size=1024 → full scale magnitude = 256 (unit sine, Hann window)
  assert_eq(band_level_db(0.0, 1024), 0)
  assert_eq(band_level_db(256.0, 1024), 10)
  assert_eq(band_level_db(128.0, 1024), 8)
  assert_eq(band_level_db(2.56, 1024), 3)
  assert_eq(band_level_db(0.0256, 1024), 0)
}

///|
fn create_display_context(
  num_bars : Int32,
  max_height : Int32,
  sub_res : Int32,
  half_fft : Int32,
  sample_rate : Int32,
  fft_size : Int32,
  show_piano : Bool,
  show_bands : Bool,
  scheme : Int32,
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
  // fire/ice paint hue by height with no per-frame rotation — one table each.
  let num_color_tables = match scheme {
    0 => 40
    _ => 1
  }
  let color_tables = precompute_color_tables(
    bar_hues, bar_sats, bar_lights, num_bars, num_color_tables, 3.0, scheme,
  )
  // Precompute stable frequency-label colors. Unlike the bars these do NOT
  // rotate with the rainbow: a coordinate axis should stay colour-stable so
  // the labels remain readable while the spectrum animates. fire/ice use one
  // warm / cool tone matching their palettes.
  let label_colors = Array::make(num_bars, "")
  match scheme {
    0 =>
      for bar in 0..<num_bars {
        let (r, g, b) = hsl_to_rgb(bar_hues[bar], 0.40, 0.62)
        label_colors[bar] = "\u001b[38;2;\{r};\{g};\{b}m"
      }
    _ => {
      // fire: warm amber axis; ice: cool cyan axis (matches each palette)
      let (r, g, b) = match scheme {
        1 => hsl_to_rgb(45.0, 0.75, 0.72)
        _ => hsl_to_rgb(200.0, 0.65, 0.72)
      }
      let tone = "\u001b[38;2;\{r};\{g};\{b}m"
      for bar in 0..<num_bars {
        label_colors[bar] = tone
      }
    }
  }
  // Row contribution: range [3.0, 17.0] for 32 brightness levels
  // Bottom rows dimmer, top rows brighter — 3D glow effect
  let row_contrib = Array::makei(max_height, fn(row) {
    3.0 + row.to_double() / max_height.to_double() * 14.0
  })
  let max_levels = max_height * sub_res
  let height_factor = 14.0 / max_levels.to_double()
  // Precompute RMS meter colors (green→yellow→red gradient, 44 levels)
  let meter_width = 44
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
  // Every row keeps the "│" axis at column 0 (labels sit inside the axis), so
  // the left scale no longer breaks on the five tick rows. Each tick is
  // emitted only once (a naive row*5/height repeats ticks, producing e.g.
  // three identical "0dB" labels in a 12-row display).
  let db_scale_labels = Array::make(max_height, "")
  let labels = ["0dB", "-6dB", "-12dB", "-18dB", "-24dB"]
  let mut prev_label_row = -1
  for row in 0..<max_height {
    let label_row = row * 5 / max_height
    if label_row < 5 && label_row != prev_label_row {
      prev_label_row = label_row
      // Single cool hue, dimming with depth, so the dB scale reads as a calm
      // instrument axis instead of five unrelated colors.
      let light = 0.64 - label_row.to_double() * 0.06
      let (r, g, b) = hsl_to_rgb(228.0, 0.28, light)
      let label = labels[label_row]
      let mut text = "\u001b[38;2;70;70;90m│\u001b[0m" +
        "\u001b[38;2;\{r};\{g};\{b}m" +
        label +
        ansi_reset
      // Pad the 5-column label field inside the axis (6 cols total).
      let pad = (5 - label.length()).clamp(min=0, max=5)
      for _ in 0..<pad {
        text = text + " "
      }
      db_scale_labels[row] = text
    } else {
      db_scale_labels[row] = "\u001b[38;2;70;70;90m│    \u001b[0m "
    }
  }
  // Precompute waveform amplitude colors — 256 levels, dim gray-blue → bright
  // cyan (no glyphs baked in: the Braille renderer supplies its own dot chars).
  let wave_amp_colors = Array::make(256, "")
  for amp in 0..<256 {
    // rainbow/ice keep the cool blue ramp; fire switches to a warm ember ramp
    // so the waveform belongs to its palette instead of clashing with it.
    let (r0, g0, b0) = match scheme {
      1 => (120, 40, 30)
      _ => (88, 98, 124)
    }
    let (r1, g1, b1) = match scheme {
      1 => (255, 200, 80)
      _ => (140, 235, 255)
    }
    let r = r0 + amp * (r1 - r0) / 255
    let g = g0 + amp * (g1 - g0) / 255
    let b = b0 + amp * (b1 - b0) / 255
    wave_amp_colors[amp] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Precompute bar offsets — eliminates per-frame Array::makei allocation
  let pre_bar_offsets = Array::makei(num_bars, fn(bar) {
    bar * num_brightness_levels
  })
  // Precompute spectrogram waterfall background tables (per-bar hue, rotating)
  let spectro_bg_tables = precompute_spectro_bg_tables(
    bar_hues, bar_sats, bar_lights, num_bars, num_color_tables, 3.0, scheme,
  )
  // Precompute band meter colors (green→yellow→red, 14 levels)
  let band_cols = Array::make(band_meter_cells, "")
  for i in 0..<band_meter_cells {
    let pct = i.to_double() / (band_meter_cells - 1).to_double()
    let hue = 120.0 * (1.0 - pct)
    let (r, g, b) = hsl_to_rgb(hue, 0.85, 0.55)
    band_cols[i] = "\u001b[38;2;\{r};\{g};\{b}m"
  }
  // Precompute perceptual band ranges (BASS/MID/TREB in bar indices)
  let (band_starts, band_ends) = band_bar_ranges(
    num_bars, half_fft, sample_rate,
  )
  // Initialize spectrogram history (3 rows × num_bars)
  let spectro_hist = Array::makei(3, fn(_) { Array::make(num_bars, 0) })
  // Precompute the spectrum baseline: "└" closes the left axis, then dashes
  // fill the remaining 65 columns so the row stays at the standard 66.
  let mut baseline = "\u001b[38;2;70;70;90m└"
  for _ in 0..<(num_bars + 5) {
    baseline = baseline + "─"
  }
  baseline = baseline + ansi_reset
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
    num_color_tables,
    color_table_idx: 0,
    row_contrib,
    height_factor,
    sample_rate,
    fft_size,
    meter_colors,
    label_strings,
    label_colors,
    db_scale_labels,
    spectrum_baseline: baseline,
    show_piano,
    show_bands,
    scheme,
    wave_amp_colors,
    bar_offsets: pre_bar_offsets,
    heights_d: Array::make(num_bars, 0.0),
    peak_heights_d: Array::make(num_bars, 0.0),
    spectrogram_history: spectro_hist,
    spectrogram_idx: 0,
    spectrogram_bg_tables: spectro_bg_tables,
    auto_gain: 1.0,
    band_colors: band_cols,
    band_levels: Array::make(3, 0.0),
    rms_level: -60.0,
    band_starts,
    band_ends,
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
    // Fully covered cell — draw solid. Previously a cell within 8 sub-levels
    // of the top was drawn as a half block ▀, leaving the lower half of the
    // cell empty and producing a visible half-cell gap under every bar top.
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
fn is_ref_line(row : Int32, max_height : Int32) -> Bool {
  row == 1 * max_height / 4
}

///|
/// Braille dot bits for one 2×4 cell: rows top→bottom, sub-columns left→right
/// (U+2800 base pattern used by terminal oscilloscopes).
let braille_dot_bits : Array[Array[Int32]] = [
  [1, 8],
  [2, 16],
  [4, 32],
  [64, 128],
]

///|
/// Render the waveform strip as a Braille-dot oscilloscope (the wave mode of
/// cli-visualizer). Each of the 60 cells is a 2×4 dot grid holding 2 samples,
/// so the curve spans 120 horizontal points and reads as a continuous line
/// instead of discrete block glyphs. Vertical min–max fill between consecutive
/// samples keeps steep slopes connected inside a cell (classic scope tracing).
/// The window stays auto-gained to its own peak; absolute loudness is carried
/// by the RMS meter.
fn render_waveform(
  sb : StringBuilder,
  waveform : Array[Double],
  width : Int32,
  pulse : Double,
  amp_colors : Array[String],
) -> Unit {
  sb.write_string("\u001b[90m   WV \u001b[0m")
  let n = waveform.length()
  if n == 0 {
    sb.write_string("\n")
    return
  }
  // Without auto-scaling the curve would collapse into the axis for quiet
  // windows; a small gate keeps true silence flat.
  let mut peak_abs = 0.0
  for j in 0..<n {
    let a = waveform.unsafe_get(j).abs()
    if a > peak_abs {
      peak_abs = a
    }
  }
  let gain = if peak_abs > 0.005 { 1.0 / peak_abs } else { 0.0 }
  let has_beat = pulse > 0.3
  let half = n / width
  let mut prev_row = 2
  for c in 0..<width {
    let mut bits = 0
    let mut amp_max = 0.0
    let mut y_sum = 0.0
    for s in 0..<half {
      let gi = c * half + s
      let y = waveform.unsafe_get(gi) * gain * 3.4
      let a = y.abs()
      if a > amp_max {
        amp_max = a
      }
      y_sum = y_sum + y
      let row = ((3.4 - y) / 6.8 * 4.0).to_int().clamp(min=0, max=3)
      // Vertical fill between this sample and the previous one keeps steep
      // slopes connected on this sub-column (scope tracing behaviour).
      let lo = if row < prev_row { row } else { prev_row }
      let hi = if row > prev_row { row } else { prev_row }
      let mut r = lo
      while r <= hi {
        bits = bits | braille_dot_bits[r][s]
        r = r + 1
      }
      prev_row = row
    }
    if bits == 0 {
      sb.write_string(" ")
      continue
    }
    let abs_amp = amp_max.clamp(min=0.0, max=1.0)
    let amp_int = (abs_amp * 255.0).to_int().clamp(min=0, max=255)
    // Beat flash on loud cells: red above the axis, blue below (by cell sign).
    if has_beat && amp_max > 0.75 {
      if y_sum >= 0.0 {
        let r = 200 + (pulse * 55.0).to_int()
        sb.write_string("\u001b[38;2;\{r};255;100m")
      } else {
        let r = 100 + (pulse * 155.0).to_int()
        sb.write_string("\u001b[38;2;\{r};150;255m")
      }
      sb.write_string("\{Int::unsafe_to_char(0x2800 + bits)}\u001b[0m")
    } else {
      sb.write_string(amp_colors.unsafe_get(amp_int))
      sb.write_string("\{Int::unsafe_to_char(0x2800 + bits)}")
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
  peak_speeds : Array[Double],
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
  let heights_d = ctx.heights_d
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
  }

  // --- Pass 2b: Monstercat neighbor fill (borrowed from cava) ---
  // A tall bar props up its neighbors: h[j] = max(h[j], h[i] / k^|i-j|).
  // Unlike averaging, this only raises valleys — real peaks survive, and the
  // spectrum reads as continuous ridges instead of sawtooth spikes.
  let mc_falloff = 1.5
  for bar in 0..<num_bars {
    heights_d.unsafe_set(bar, heights[bar].to_double())
  }
  for i in 0..<num_bars {
    let v = heights_d.unsafe_get(i)
    if v < 1.0 {
      continue
    }
    let mut d = 1
    let mut fall = 1.0
    while d < num_bars {
      fall = fall / mc_falloff
      let fill = v * fall
      if fill < 0.5 {
        break
      }
      let l = i - d
      if l >= 0 && heights_d.unsafe_get(l) < fill {
        heights_d.unsafe_set(l, fill)
      }
      let r = i + d
      if r < num_bars && heights_d.unsafe_get(r) < fill {
        heights_d.unsafe_set(r, fill)
      }
      d = d + 1
    }
  }
  for bar in 0..<num_bars {
    heights[bar] = (heights_d.unsafe_get(bar) + 0.5).to_int()
  }

  // --- Pass 2c: peak hold update (after neighbor fill, so caps follow the
  // envelope instead of lagging one frame behind the propped-up valleys) ---
  // cava-style caps: hold above the bar for a few frames, then fall with
  // accelerating gravity (1 row/frame², capped at 3 rows/frame) instead of
  // exponential decay — the drop starts lazy and finishes snappy.
  for bar in 0..<num_bars {
    let h = heights[bar]
    if h >= peak_heights[bar] {
      peak_heights[bar] = h
      peak_frames[bar] = 0
      peak_speeds[bar] = 0.0
    } else if peak_frames[bar] > 3 {
      let sp = (peak_speeds[bar] + 8.0).clamp(min=0.0, max=24.0)
      peak_speeds[bar] = sp
      let dropped = (peak_heights[bar].to_double() - sp).to_int()
      peak_heights[bar] = if dropped < h { h } else { dropped }
      peak_frames[bar] = 0
    } else {
      peak_frames[bar] = peak_frames[bar] + 1
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
    // Calm border follows the palette: cyan (rainbow) / amber (fire) / ice
    match ctx.scheme {
      1 => "\u001b[38;2;235;150;70m"
      2 => "\u001b[38;2;120;200;240m"
      _ => "\u001b[38;2;90;200;230m"
    }
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
  // Outer frame width == spectrum body width (6+l bars + 2 borders = 66)
  let header_width = num_bars + 4
  let text_width = header_width - 2
  let title = truncate_to_width(
    "🎵 MoonFFTmusic — Real-time Spectrum Analyzer", text_width,
  )
  let beat_indicator = if beat_pulse > 0.5 { " ♫" } else { "" }
  let bpm_str = if bpm > 0.0 { " | \{bpm.to_int()} BPM" } else { "" }
  // Colour-code the info line so live values read above static labels:
  // dim labels, accent peak frequency, accent note, accent BPM, dim time.
  // Accents follow the palette — cool cyan/yellow on rainbow, gold/coral on
  // fire, icy blue/violet on ice — so the header belongs to its scheme.
  let info_dim = "\u001b[38;2;120;132;158m"
  let accent_freq = match ctx.scheme {
    1 => "\u001b[1;38;2;255;190;90m"
    2 => "\u001b[1;38;2;150;220;255m"
    _ => "\u001b[1;38;2;110;220;240m"
  }
  let accent_note = match ctx.scheme {
    1 => "\u001b[38;2;255;145;115m"
    2 => "\u001b[38;2;200;180;255m"
    _ => "\u001b[38;2;250;205;90m"
  }
  let accent_beat = match ctx.scheme {
    1 => "\u001b[1;38;2;255;120;90m"
    2 => "\u001b[1;38;2;170;220;255m"
    _ => "\u001b[1;38;2;255;170;90m"
  }
  let accent_bpm = match ctx.scheme {
    1 => "\u001b[38;2;255;170;120m"
    2 => "\u001b[38;2;150;230;230m"
    _ => "\u001b[38;2;150;220;130m"
  }
  let rate_str = "\{sample_rate}Hz | FFT \{fft_size}"
  let freq_str = format_freq(dominant_freq_int)
  let note_str = " (\{note_name})"
  let info_plain = rate_str +
    " | Peak " +
    freq_str +
    note_str +
    beat_indicator +
    bpm_str +
    " | " +
    format_time(current_pos, sample_rate)

  sb.write_string(beat_glow)
  sb.write_string("╔")
  for _ in 0..<header_width {
    sb.write_string(border_char)
  }
  sb.write_string("╗\n║ ")
  // Centre the title inside the frame: the live info row below is dense, so a
  // centred title keeps the two header rows visually balanced.
  let title_lead = ((text_width - display_width(title)) / 2).clamp(
    min=0,
    max=text_width,
  )
  for _ in 0..<title_lead {
    sb.write_string(" ")
  }
  sb.write_string(title)
  let title_pad = (text_width - display_width(title) - title_lead).clamp(
    min=0,
    max=header_width,
  )
  for _ in 0..<title_pad {
    sb.write_string(" ")
  }
  sb.write_string(" ║\n║ ")
  // Fall back to a single dim run if the line would overflow the frame.
  if display_width(info_plain) > text_width {
    let truncated = truncate_to_width(info_plain, text_width)
    sb.write_string(info_dim)
    sb.write_string(truncated)
    sb.write_string("\u001b[0m")
    let pad = (text_width - display_width(truncated)).clamp(
      min=0,
      max=text_width,
    )
    for _ in 0..<pad {
      sb.write_string(" ")
    }
  } else {
    sb.write_string(info_dim)
    sb.write_string(rate_str)
    sb.write_string(" | Peak ")
    sb.write_string(accent_freq)
    sb.write_string(freq_str)
    sb.write_string(accent_note)
    sb.write_string(note_str)
    sb.write_string(info_dim)
    if beat_pulse > 0.5 {
      sb.write_string(accent_beat)
      sb.write_string(" ♫")
      sb.write_string(info_dim)
    }
    if bpm > 0.0 {
      sb.write_string(accent_bpm)
      sb.write_string(bpm_str)
      sb.write_string(info_dim)
    }
    sb.write_string(" | ")
    sb.write_string(format_time(current_pos, sample_rate))
    sb.write_string("\u001b[0m")
    let pad = (text_width - display_width(info_plain)).clamp(
      min=0,
      max=text_width,
    )
    for _ in 0..<pad {
      sb.write_string(" ")
    }
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
  // The left axis also runs through this row so the frame is continuous from
  // the header corner down to the baseline (6-column gutter is preserved).
  sb.write_string("\u001b[38;2;70;70;90m│     \u001b[0m")
  for bar in 0..<num_bars {
    if heights[bar] > 0 {
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
      let glyph = connector_char(left_h, blend_h, right_h)
      if bar == dom_bar {
        // Dominant bar: highlight the contour glyph itself instead of
        // replacing it with ▼ — the envelope shape stays intact (a highlight
        // must not replace structural characters, same rule as the keyboard).
        sb.write_string("\u001b[1;33m")
        sb.write_string(glyph)
        sb.write_string("\u001b[0m")
      } else {
        sb.write_string(
          color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level),
        )
        sb.write_string(glyph)
      }
    } else if ctx.is_grid[bar] {
      sb.write_string("\u001b[38;2;58;72;104m")
      sb.write_string("╎\u001b[0m")
    } else {
      sb.write_string(" ")
    }
  }
  sb.write_string("\n")

  // --- Piano keyboard row — shows detected note on 2-octave keyboard ---
  // Dropped on short terminals (<24 lines): the bar field gets the space.
  if ctx.show_piano {
    let dom_midi = if dominant_freq > 0 {
      (69.0 + 12.0 * @math.log2(dominant_freq / 440.0))
      .round()
      .to_int()
      .clamp(min=48, max=71)
    } else {
      -1
    }
    render_piano_keyboard(sb, num_bars, dom_midi, beat_pulse, beat_count)
  }

  // --- Render bars with precomputed color table (continuous, no gaps) ---
  // Precompute heights[bar] * height_factor once — avoids to_double + multiply
  // per bar per row (saves 2 ops × 60 bars × 20 rows = 2400 ops/frame)
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
        PartialBlock(frac) => {
          // Top tip: a lower-fraction block that sits flush on the full cells
          // below (no gap), with a crown glow (+8) marking the bar's crest.
          let level = (row_base + heights_d.unsafe_get(bar) + 8.0)
            .to_int()
            .clamp(min=0, max=nbl_minus_1)
          sb.write_string(color_tbl.unsafe_get(bar_off + level))
          sb.write_string(partial_blocks[frac])
        }
        PeakMarker => {
          // Bright off-white cap (cava convention): the ━ glyph carries the
          // distinction in monochrome, the glow makes it pop off the rainbow.
          sb.write_string("\u001b[1;38;2;246;246;232m")
          sb.write_string("━")
          sb.write_string("\u001b[0m")
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

  // --- Spectrum baseline — closes the left axis under the last bar row ---
  sb.write_string(ctx.spectrum_baseline)
  sb.write_string("\n")

  // --- Spectrogram waterfall: 3 rows of recent spectrum history ---
  // Each row shows a previous frame; hue = frequency (matches the bars),
  // brightness = intensity and age. Row 0 = most recent, Row 2 = oldest.
  let spectro_hist = ctx.spectrogram_history
  let spectro_idx = ctx.spectrogram_idx
  let spectro_tbl = ctx.spectrogram_bg_tables.unsafe_get(ctx.color_table_idx)
  for row in 0..<3 {
    sb.write_string("\u001b[90m      \u001b[0m")
    // Age cue: the newest history row gets +2 brightness levels, the oldest
    // -3. The table's hue shifts only ~1.1°/level, so frequency colour stays
    // continuous while the three rows read as a time sequence.
    let age_offset = match row {
      0 => 2
      1 => 0
      _ => -3
    }
    // Get the historical frame: row 0 = most recent (current frame - 1)
    // row 1 = 2 frames ago, row 2 = 3 frames ago
    let hist_idx = (spectro_idx - 1 - row + 3) % 3
    let hist_row = spectro_hist.unsafe_get(hist_idx)
    for bar in 0..<num_bars {
      let h = hist_row.unsafe_get(bar)
      if h > 0 {
        let level = ((h.to_double() * height_factor + 3.0).to_int() + age_offset).clamp(
          min=0,
          max=nbl_minus_1,
        )
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
  // Pad the axis row to the full spectrum width so it ends flush with the
  // body instead of stopping a few columns short.
  while label_pos < num_bars {
    sb.write_string(" ")
    label_pos = label_pos + 1
  }
  sb.write_string("\n")

  // --- Waveform strip ---
  render_waveform(sb, waveform, num_bars, beat_pulse, ctx.wave_amp_colors)

  // --- Energy history sparkline (MoonBit `mut` circular buffer) ---
  // Dropped on short terminals (<24 lines) together with the piano row.
  if ctx.show_bands {
    render_band_meters(
      sb,
      magnitudes,
      ctx.band_starts,
      ctx.band_ends,
      ctx.fft_size,
      ctx.band_colors,
      ctx.band_levels,
    )
  }

  // --- RMS meter ---
  let raw_db = if rms_value > 0.0 {
    20.0 * @math.log10(rms_value)
  } else {
    -99.0
  }
  // IIR smoothing (fast attack / slow release), the same VU-meter character
  // as the band meters — raw per-frame RMS can jump ~15dB on a transient hit,
  // which made the 44-cell bar lurch by 10+ cells in a single frame.
  let rms_db = if raw_db >= ctx.rms_level {
    ctx.rms_level * 0.55 + raw_db * 0.45
  } else {
    ctx.rms_level * 0.85 + raw_db * 0.15
  }
  ctx.rms_level = rms_db
  let rms_pct = ((rms_db + 60.0) / 60.0).clamp(min=0.0, max=1.0)
  let meter_width = ctx.meter_colors.length()
  let meter_filled = (rms_pct * meter_width.to_double() + 0.5)
    .to_int()
    .clamp(min=0, max=meter_width)

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
  let db_text = "\{db_int}.\{db_frac} dB"
  sb.write_string(db_text)
  // Pad the readout to a fixed 8 columns so the RMS row stays exactly as wide
  // as the spectrum body for both "-8.8 dB" and "-26.5 dB".
  let db_pad = (8 - display_width(db_text)).clamp(min=0, max=8)
  for _ in 0..<db_pad {
    sb.write_string(" ")
  }
  sb.write_string("\n")

  // --- Progress bar (kept inside the 66-column body) ---
  let progress_pct = if total_samples > 0 {
    current_pos.to_double() / total_samples.to_double()
  } else {
    0.0
  }
  let pct_int = (progress_pct * 100.0).to_int()
  let pct_text = "\{pct_int}%"
  let time_text = "\{format_time(current_pos, sample_rate)} / \{total_time_str}"
  // Reserve room for the percentage + time readout so the whole row never
  // exceeds the spectrum width (it used to overflow by ~13 columns).
  let info_width = display_width(pct_text) + 1 + display_width(time_text)
  let progress_width = (num_bars - info_width - 1).clamp(min=10, max=num_bars)
  let progress_filled = (progress_pct * progress_width.to_double()).to_int()

  // Progress bar with beat-reactive pulse (bold on beat hits)
  let prog_glow = if beat_pulse > 0.3 { "\u001b[1m" } else { "" }
  sb.write_string("      ")
  for i in 0..<progress_width {
    // Sample the 60-step cyan→violet ramp across the shorter bar so the
    // gradient still spans its full range.
    let color_idx = (i.to_double() /
      progress_width.to_double() *
      (num_bars - 1).to_double())
      .to_int()
      .clamp(min=0, max=num_bars - 1)
    if i < progress_filled {
      sb.write_string(prog_glow)
      sb.write_string(ctx.progress_colors.unsafe_get(color_idx))
      sb.write_string("║")
    } else if i == progress_filled {
      sb.write_string(prog_glow)
      sb.write_string(ctx.progress_colors.unsafe_get(color_idx))
      sb.write_string("▓")
    } else {
      sb.write_string("\u001b[90m░")
    }
  }
  sb.write_string("\u001b[0m ")
  sb.write_string(pct_text)
  sb.write_string(" ")
  sb.write_string(time_text)

  sb.to_string()
}
