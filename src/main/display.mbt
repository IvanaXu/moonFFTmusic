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
  db_scale_labels : Array[String]
  waveform_colors : Array[String]
  bar_offsets : Array[Int32]
}

///|
struct BeatDetector {
  energy_history : Array[Double]
  mut history_idx : Int32
  history_size : Int32
  mut beat_intensity : Double
  mut energy_sum : Double
}

///|
fn BeatDetector::new(history_size : Int32) -> BeatDetector {
  BeatDetector::{
    energy_history: Array::make(history_size, 0.0),
    history_idx: 0,
    history_size,
    beat_intensity: 0.0,
    energy_sum: 0.0,
  }
}

///|
fn BeatDetector::update(self : BeatDetector, rms : Double) -> Double {
  let energy = rms * rms
  let idx = self.history_idx
  self.energy_sum -= self.energy_history[idx]
  self.energy_history[idx] = energy
  self.energy_sum += energy
  self.history_idx = (idx + 1) % self.history_size
  let avg = self.energy_sum / self.history_size.to_double()
  if energy > avg * 1.4 && energy > 0.001 {
    self.beat_intensity = 1.0
  } else {
    self.beat_intensity *= 0.92
  }
  self.beat_intensity
}

///|
/// Energy history sparkline — compact one-line RMS energy trend graph.
/// Uses MoonBit `mut` struct fields for circular buffer state.
struct EnergySparkline {
  history : Array[Double]
  mut idx : Int32
  size : Int32
  mut max_energy : Double
} derive(Debug)

///|
fn EnergySparkline::new(size : Int32) -> EnergySparkline {
  EnergySparkline::{
    history: Array::make(size, 0.0),
    idx: 0,
    size,
    max_energy: 0.001,
  }
}

///|
/// Push new RMS value into circular buffer; track running max with decay.
fn EnergySparkline::push(self : EnergySparkline, rms : Double) -> Unit {
  let energy = rms * rms
  self.history.unsafe_set(self.idx, energy)
  self.idx = (self.idx + 1) % self.size
  // Adaptive max with slow decay — auto-adjusts to dynamic range
  self.max_energy = (self.max_energy * 0.995).clamp(min=0.001, max=1.0)
  if energy > self.max_energy {
    self.max_energy = energy
  }
}

///|
/// Sparkline character set — MoonBit `Array` literal with Unicode partial blocks
let sparkline_chars : Array[String] = [
  "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
]

///|

///|
let sparkline_colors : Array[String] = [
  "\u001b[38;2;255;80;40m", "\u001b[38;2;255;90;40m", "\u001b[38;2;255;100;40m",
  "\u001b[38;2;255;110;40m", "\u001b[38;2;255;120;40m", "\u001b[38;2;255;130;40m",
  "\u001b[38;2;255;140;40m", "\u001b[38;2;255;150;40m", "\u001b[38;2;255;180;40m",
  "\u001b[38;2;255;180;50m", "\u001b[38;2;255;180;60m", "\u001b[38;2;255;180;70m",
  "\u001b[38;2;255;180;80m", "\u001b[38;2;255;180;90m", "\u001b[38;2;255;180;100m",
  "\u001b[38;2;255;180;110m", "\u001b[38;2;80;220;80m", "\u001b[38;2;100;220;80m",
  "\u001b[38;2;120;220;80m", "\u001b[38;2;140;220;80m", "\u001b[38;2;160;220;80m",
  "\u001b[38;2;180;220;80m", "\u001b[38;2;200;220;80m", "\u001b[38;2;220;220;80m",
  "\u001b[38;2;40;100;200m", "\u001b[38;2;40;115;200m", "\u001b[38;2;40;130;200m",
  "\u001b[38;2;40;145;200m", "\u001b[38;2;40;160;200m", "\u001b[38;2;40;175;200m",
  "\u001b[38;2;40;190;200m", "\u001b[38;2;40;205;200m",
]

///|
/// Render energy sparkline as a compact one-line graph.
/// Uses MoonBit `match` for color zone selection and `Array::unsafe_get` for hot path.
fn render_energy_sparkline(
  sb : StringBuilder,
  sparkline : EnergySparkline,
  width : Int32,
) -> Unit {
  let n = sparkline.size
  let hist = sparkline.history
  let max_e = sparkline.max_energy
  let step = n.to_double() / width.to_double()
  sb.write_string("\u001b[90m  EN \u001b[0m")
  for i in 0..<width {
    // Map display position to circular buffer index (oldest → newest)
    let buf_idx = ((sparkline.idx.to_double() + i.to_double() * step).to_int() %
    n).clamp(min=0, max=n - 1)
    let energy = hist.unsafe_get(buf_idx)
    let ratio = (energy / max_e).clamp(min=0.0, max=1.0)
    // Precomputed color table: 4 zones × 8 char_idx = 32 entries
    let char_idx = (ratio * 7.0).to_int().clamp(min=0, max=7)
    let zone = if ratio > 0.75 {
      0
    } else if ratio > 0.5 {
      1
    } else if ratio > 0.25 {
      2
    } else {
      3
    }
    sb.write_string(sparkline_colors.unsafe_get(zone * 8 + char_idx))
    sb.write_string(sparkline_chars.unsafe_get(char_idx))
  }
  sb.write_string("\u001b[0m\n")
}

///|
/// Peak frequency trail — tracks dominant frequency bar position over time.
/// Uses MoonBit `mut` struct fields for circular buffer; `enum` for fade levels.
struct PeakTrail {
  history : Array[Int32] // bar positions (-1 = no peak)
  mut idx : Int32
  size : Int32
  bar_fade : Array[Int32] // reusable per-bar fade levels (avoids per-frame alloc)
}

///|
/// Trail fade level — MoonBit `enum` for rendering dispatch
enum TrailFade {
  Fresh // most recent — bright dot
  Recent // medium fade
  Old // dim fade
  Gone // too old — don't render
}

///|
fn PeakTrail::new(size : Int32) -> PeakTrail {
  PeakTrail::{
    history: Array::make(size, -1),
    idx: 0,
    size,
    bar_fade: Array::make(size, 4), // 4 = Gone (default)
  }
}

///|
fn PeakTrail::push(self : PeakTrail, bar : Int32) -> Unit {
  self.history.unsafe_set(self.idx, bar)
  self.idx = (self.idx + 1) % self.size
}

///|
/// Classify trail age into fade level — MoonBit `match` with guard patterns
fn trail_fade(age : Int32, size : Int32) -> TrailFade {
  let ratio = age.to_double() / size.to_double()
  match ratio {
    r if r < 0.15 => Fresh
    r if r < 0.4 => Recent
    r if r < 0.7 => Old
    _ => Gone
  }
}

///|
/// Render peak frequency trail as a row above the spectrum bars.
/// Shows where the dominant frequency has been over recent frames with fading dots.
/// Uses MoonBit `match` on `TrailFade` enum for rendering dispatch.
fn render_peak_trail(
  sb : StringBuilder,
  trail : PeakTrail,
  num_bars : Int32,
  color_tbl : Array[String],
  bar_offsets : Array[Int32],
) -> Unit {
  sb.write_string("\u001b[90m     \u001b[0m")
  // Reuse trail.bar_fade — reset to 4 (Gone) then fill
  let bar_fade = trail.bar_fade
  for i in 0..<num_bars {
    bar_fade.unsafe_set(i, 4)
  }
  let n = trail.size
  let hist = trail.history
  for age in 0..<n {
    // age=0 is most recent, age=n-1 is oldest
    let buf_idx = (trail.idx - 1 - age + n) % n
    let bar = hist.unsafe_get(buf_idx)
    if bar >= 0 && bar < num_bars {
      let fade = match trail_fade(age, n) {
        Fresh => 0
        Recent => 1
        Old => 2
        Gone => 3
      }
      // Only update if this bar hasn't been set by a more recent entry
      if bar_fade.unsafe_get(bar) > fade {
        bar_fade.unsafe_set(bar, fade)
      }
    }
  }
  // Render the trail row
  for bar in 0..<num_bars {
    let bar_off = bar_offsets.unsafe_get(bar)
    match bar_fade.unsafe_get(bar) {
      0 => { // Fresh — bright pulsing dot
        sb.write_string(color_tbl.unsafe_get(bar_off + 28))
        sb.write_string("●")
      }
      1 => { // Recent — medium dot
        sb.write_string(color_tbl.unsafe_get(bar_off + 20))
        sb.write_string("•")
      }
      2 => { // Old — dim dot
        sb.write_string(color_tbl.unsafe_get(bar_off + 10))
        sb.write_string("·")
      }
      _ => sb.write_string(" ")
    }
  }
  sb.write_string("\u001b[0m\n")
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
) -> (
  Array[Int32],
  Array[Int32],
  Array[Int32],
  Array[Double],
  Array[Double],
  Array[Double],
) {
  let bar_r = Array::make(num_bars, 0)
  let bar_g = Array::make(num_bars, 0)
  let bar_b = Array::make(num_bars, 0)
  let bar_hues = Array::make(num_bars, 0.0)
  let bar_sats = Array::make(num_bars, 0.0)
  let bar_lights = Array::make(num_bars, 0.0)
  for bar in 0..<num_bars {
    let ratio = bar.to_double() / (num_bars - 1).to_double()
    // Hue: 260 (indigo) -> 0 (red), wide vibrant spectrum
    let hue = 260.0 * (1.0 - ratio)
    // Saturation: peaks at mid-range (0.95), lower at extremes (0.75)
    let sat = 0.75 + 0.2 * (1.0 - (2.0 * ratio - 1.0).abs())
    // Lightness: darker at bass (0.42), brighter at treble (0.60)
    let light = 0.42 + 0.18 * ratio
    let (r, g, b) = hsl_to_rgb(hue, sat, light)
    bar_r[bar] = r
    bar_g[bar] = g
    bar_b[bar] = b
    bar_hues[bar] = hue
    bar_sats[bar] = sat
    bar_lights[bar] = light
  }
  (bar_r, bar_g, bar_b, bar_hues, bar_sats, bar_lights)
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
      let (br, bg, bb) = hsl_to_rgb(hue, sat, light)
      let bar_off = bar * nbl
      for level in 0..<nbl {
        let brightness = 0.15 + level.to_double() / (nbl - 1).to_double() * 0.85
        let r = (br.to_double() * brightness).clamp(min=0.0, max=255.0).to_int()
        let g = (bg.to_double() * brightness).clamp(min=0.0, max=255.0).to_int()
        let b = (bb.to_double() * brightness).clamp(min=0.0, max=255.0).to_int()
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
  let (_, _, _, bar_hues, bar_sats, bar_lights) = precompute_bar_colors(
    num_bars,
  )
  let color_tables = precompute_color_tables(
    bar_hues, bar_sats, bar_lights, num_bars, 40, 3.0,
  )
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
  // Precompute frequency label strings — eliminates per-frame nested loop
  // and format_freq calls. label_strings[bar] = colored label or ""
  let label_strings = Array::make(num_bars, "")
  for j in 0..<grid_bars.length() {
    let gb = grid_bars[j]
    if gb >= 0 && gb < num_bars {
      let hz = freq_labels[j]
      let label = if hz >= 1000 { "\{hz / 1000}kHz" } else { "\{hz}Hz" }
      // Color from color_table at brightness level 18
      let bar_off = gb * num_brightness_levels
      label_strings[gb] = color_tables[0][bar_off + 18] + label + ansi_reset
    }
  }
  // Precompute dB scale labels — eliminates per-frame hsl_to_rgb calls
  let db_scale_labels = Array::make(max_height, "")
  for row in 0..<max_height {
    let label_row = row * 5 / max_height
    if label_row < 5 {
      let hue = 260.0 - label_row.to_double() * 52.0
      let (r, g, b) = hsl_to_rgb(hue, 0.3, 0.6)
      let labels = [" 0dB", "-6dB", "-12dB", "-18dB", "-24dB"]
      db_scale_labels[row] = "\u001b[38;2;\{r};\{g};\{b}m" +
        labels[label_row] +
        ansi_reset +
        " "
    } else {
      db_scale_labels[row] = "\u001b[38;2;70;70;90m│" + ansi_reset + " "
    }
  }
  // Precompute waveform color table — 9 scaled values × 256 amplitude levels
  // Index: (scaled + 4) * 256 + amp_int. Eliminates per-frame string interpolation.
  // Beat cases (scaled 3|4, -3|-4) store non-beat colors; beat override is rare.
  let wf_tbl = Array::make(9 * 256, "")
  for amp in 0..<256 {
    // scaled 0: fixed dim color
    wf_tbl[4 * 256 + amp] = "\u001b[38;2;60;70;90m─\u001b[0m"
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
    db_scale_labels,
    waveform_colors: wf_tbl,
    bar_offsets: pre_bar_offsets,
    heights_d: Array::make(num_bars, 0.0),
    peak_heights_d: Array::make(num_bars, 0.0),
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
  beat_intensity : Double,
  wf_colors : Array[String],
) -> Unit {
  sb.write_string("\u001b[90m  WV \u001b[0m")
  let n = waveform.length()
  if n == 0 {
    sb.write_string("\n")
    return
  }
  let step = n.to_double() / width.to_double()
  let has_beat = beat_intensity > 0.3
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
        let r = 200 + (beat_intensity * 55.0).to_int()
        sb.write_string("\u001b[38;2;\{r};255;100m█\u001b[0m")
      } else {
        let r = 100 + (beat_intensity * 155.0).to_int()
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
  sparkline : EnergySparkline,
  peak_trail : PeakTrail,
  dom_bar : Int32,
) -> String {
  let sb = StringBuilder::StringBuilder()
  let num_bars = ctx.num_bars
  let max_height = ctx.max_height
  let sub_res = ctx.sub_res
  let max_levels = ctx.max_levels
  let sample_rate = ctx.sample_rate
  let fft_size = ctx.fft_size

  sb.write_string(ansi_clear)

  // --- Fused pass 1: height calc + attack/release envelope ---
  // dominant_bar (dom_bar) is passed in with sticky logic from main.mbt
  for bar in 0..<num_bars {
    let mag = magnitudes[bar]
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

  // --- Dominant frequency + note ---
  let dominant_bin = ctx.bin_map[dom_bar]
  let dominant_freq = dominant_bin * sample_rate / fft_size
  let note_name = freq_to_note(dominant_freq)

  // --- Beat glow border with flash effect ---
  // Strong beat: bright white-yellow flash; medium: orange-red; calm: cyan
  let beat_glow = if beat_intensity > 0.6 {
    // Flash: bright white-yellow on strong beats
    "\u001b[1;38;2;255;255;\{(180 + (beat_intensity * 75.0).to_int())}m"
  } else if beat_intensity > 0.1 {
    "\u001b[38;2;255;\{(beat_intensity * 200.0).to_int()};\{(beat_intensity * 100.0).to_int()}m"
  } else {
    "\u001b[1;36m"
  }
  // Beat pulse: scale border thickness character on strong beats
  let border_char = if beat_intensity > 0.5 { "━" } else { "═" }

  // --- Beat-reactive brightness boost (shift color level up to 4) ---
  // Beat bloom: brightness boost on all bars, more dramatic on strong beats
  let beat_boost = (beat_intensity * 10.0).to_int()
  // Scanline: a gentle highlight row that sweeps up and down
  // Uses current_pos as time source — no extra parameter needed
  let scan_cycle = max_height * 2
  let scan_raw = current_pos / sub_res % scan_cycle
  let scan_row = if scan_raw < max_height {
    scan_raw
  } else {
    scan_cycle - scan_raw - 1
  }

  // --- Header ---
  let header_width = num_bars + 6
  let title = "🎵 MoonFFTmusic — Real-time Spectrum Analyzer"
  let beat_indicator = if beat_intensity > 0.5 { " ♫" } else { "  " }
  let info_line = "Rate: \{sample_rate}Hz | FFT: \{fft_size} | Bars: \{num_bars} | Peak: \{format_freq(dominant_freq)} (\{note_name})\{beat_indicator} | \{format_time(current_pos, sample_rate)}"

  sb.write_string(beat_glow)
  sb.write_string("╔")
  for _ in 0..<header_width {
    sb.write_string(border_char)
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
  sb.write_string("\u001b[90m     \u001b[0m")
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
      let level = (heights[bar].to_double() * height_factor + 12.0)
        .to_int()
        .clamp(min=4, max=nbl_minus_1)
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level))
      sb.write_string(connector_char(left_h, blend_h, right_h))
    } else if ctx.is_grid[bar] {
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + 3))
      sb.write_string("╎\u001b[0m")
    } else {
      sb.write_string(" ")
    }
  }
  sb.write_string("\n")

  // --- Peak frequency trail row (MoonBit `enum` + `match` fade dispatch) ---
  render_peak_trail(sb, peak_trail, num_bars, color_tbl, bar_offsets)

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
          let level = (row_base + heights_d.unsafe_get(bar))
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
            sb.write_string(color_tbl.unsafe_get(bar_off + 3))
            sb.write_string("╎\u001b[0m")
          } else if ref_line {
            sb.write_string(color_tbl.unsafe_get(bar_off + 2))
            sb.write_string("┄\u001b[0m")
          } else {
            sb.write_string(" ")
          }
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Mirror reflection: inverted bars with fading colors (3 rows) ---
  // Creates a "water reflection" effect — bars mirror downward with
  // decreasing brightness, giving a 3D depth illusion.
  for mirror_row in 0..<3 {
    sb.write_string("\u001b[90m     \u001b[0m")
    // Each mirror row shows a lower slice of the bar, with fading brightness
    let mirror_slice = (mirror_row + 1) * sub_res
    // Fade: row 0 = 60% brightness, row 1 = 35%, row 2 = 15%
    let fade_level = match mirror_row {
      0 => 14
      1 => 8
      _ => 3
    }
    for bar in 0..<num_bars {
      let h = heights[bar]
      if h > mirror_slice {
        // Full block in mirror
        let level = (heights_d.unsafe_get(bar) * 0.5 + fade_level.to_double())
          .to_int()
          .clamp(min=0, max=nbl_minus_1)
        sb.write_string(
          color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level),
        )
        sb.write_string("█")
      } else if h > mirror_slice - sub_res && h > 0 {
        // Partial block at mirror edge
        let level = (heights_d.unsafe_get(bar) * 0.4 + fade_level.to_double())
          .to_int()
          .clamp(min=0, max=nbl_minus_1)
        sb.write_string(
          color_tbl.unsafe_get(bar_offsets.unsafe_get(bar) + level),
        )
        sb.write_string("▄")
      } else {
        sb.write_string(" ")
      }
    }
    sb.write_string(ansi_reset)
    sb.write_string("\n")
  }

  // --- Frequency labels (precomputed text) ---
  sb.write_string("     ")
  let mut label_pos = 0
  for i in 0..<num_bars {
    let label = ctx.label_strings.unsafe_get(i)
    if label.length() > 0 {
      while label_pos < i {
        sb.write_string(" ")
        label_pos = label_pos + 1
      }
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(i) + 18))
      sb.write_string(label)
      sb.write_string(ansi_reset)
      label_pos = i + label.length()
    }
  }
  sb.write_string("\n")

  // --- Waveform strip ---
  render_waveform(sb, waveform, num_bars, beat_intensity, ctx.waveform_colors)

  // --- Energy history sparkline (MoonBit `mut` circular buffer) ---
  render_energy_sparkline(sb, sparkline, num_bars)

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
  sb.write_string("\u001b[1;37mRMS: \u001b[0m[")
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

  for i in 0..<num_bars {
    if i < progress_filled {
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(i) + 28))
      sb.write_string("║")
    } else if i == progress_filled {
      sb.write_string(color_tbl.unsafe_get(bar_offsets.unsafe_get(i) + 28))
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
