// =============================================================================
// FFT Module — Radix-2 Cooley-Tukey Fast Fourier Transform
//
// Two implementations:
//   1. Complex-based (original) — kept for tests and API compatibility
//   2. SoA (Structure of Arrays) — zero-allocation hot loop for production
//
// SoA optimization: separate Array[Double] for real/imaginary parts eliminates
// all Complex object allocations in the butterfly loop. For N=1024, this saves
// ~15,000 allocations per frame. Twiddle factors are precomputed once and reused
// across all FFT calls via a single strided table.
// =============================================================================

///|
struct Complex {
  re : Double
  im : Double
} derive(Debug)

///|
fn Complex::mag(self : Complex) -> Double {
  (self.re * self.re + self.im * self.im).sqrt()
}

///|
fn Complex::add(self : Complex, other : Complex) -> Complex {
  Complex::{ re: self.re + other.re, im: self.im + other.im, }
}

///|
fn Complex::sub(self : Complex, other : Complex) -> Complex {
  Complex::{ re: self.re - other.re, im: self.im - other.im, }
}

///|
fn Complex::mul(self : Complex, other : Complex) -> Complex {
  Complex::{
    re: self.re * other.re - self.im * other.im,
    im: self.re * other.im + self.im * other.re,
  }
}

///|
fn Complex::scale(self : Complex, s : Double) -> Complex {
  Complex::{ re: self.re * s, im: self.im * s, }
}

///|
fn Complex::from_polar(r : Double, theta : Double) -> Complex {
  Complex::{ re: r * @math.cos(theta), im: r * @math.sin(theta), }
}

///|
fn log2_int(n : Int32) -> Int32 {
  let mut bits = 0
  let mut x = n
  while x > 1 {
    x = x >> 1
    bits += 1
  }
  bits
}

///|
fn bit_reverse(n : Int32, bits : Int32) -> Int32 {
  let mut result : Int32 = 0
  let mut x = n
  for _ in 0..<bits {
    result = (result << 1) | (x & 1)
    x = x >> 1
  }
  result
}

///|
fn precompute_twiddles(half_size : Int32) -> Array[Complex] {
  let angle = -2.0 * @math.PI / (half_size * 2).to_double()
  Array::makei(half_size, fn(k) {
    Complex::from_polar(1.0, angle * k.to_double())
  })
}

///|
fn fft(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let bits = log2_int(n)
  for i in 0..<n {
    let j = bit_reverse(i, bits)
    if j > i {
      let temp = data[i]
      data[i] = data[j]
      data[j] = temp
    }
  }
  let mut size : Int32 = 2
  while size <= n {
    let half = size / 2
    let twiddles = precompute_twiddles(half)
    let mut start = 0
    while start < n {
      for j in 0..<half {
        let idx1 = start + j
        let idx2 = start + j + half
        let t = data.unsafe_get(idx2).mul(twiddles.unsafe_get(j))
        let orig = data.unsafe_get(idx1)
        data.unsafe_set(idx1, orig.add(t))
        data.unsafe_set(idx2, orig.sub(t))
      }
      start += size
    }
    size *= 2
  }
}

///|
fn apply_hann_window(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let denom = (n - 1).to_double()
  data.mapi_in_place(fn(i, z) {
    let hann = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / denom))
    z.scale(hann)
  })
}

// =============================================================================
// SoA (Structure of Arrays) FFT — Zero-allocation production path
// =============================================================================

///|
fn precompute_twiddles_soa(n : Int32) -> (Array[Double], Array[Double]) {
  let half = n / 2
  let angle = -2.0 * @math.PI / n.to_double()
  let tw_re = Array::make(half, 0.0)
  let tw_im = Array::make(half, 0.0)
  for k in 0..<half {
    let theta = angle * k.to_double()
    tw_re[k] = @math.cos(theta)
    tw_im[k] = @math.sin(theta)
  }
  (tw_re, tw_im)
}

///|
fn precompute_hann_window(n : Int32) -> Array[Double] {
  if n <= 1 {
    return Array::make(n, 1.0)
  }
  let denom = (n - 1).to_double()
  Array::makei(n, fn(i) {
    0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / denom))
  })
}

///|
fn precompute_bit_reversal(n : Int32, bits : Int32) -> Array[Int32] {
  let table = Array::make(n, 0)
  for i in 0..<n {
    let mut result : Int32 = 0
    let mut x = i
    for _ in 0..<bits {
      result = (result << 1) | (x & 1)
      x = x >> 1
    }
    table[i] = result
  }
  table
}

///|
fn fft_soa(
  re : Array[Double],
  im : Array[Double],
  tw_re : Array[Double],
  tw_im : Array[Double],
  bit_rev : Array[Int32],
) -> Unit {
  let n = re.length()
  if n <= 1 {
    return
  }
  for i in 0..<n {
    let j = bit_rev.unsafe_get(i)
    if j > i {
      let tr = re.unsafe_get(i)
      let ti = im.unsafe_get(i)
      re.unsafe_set(i, re.unsafe_get(j))
      im.unsafe_set(i, im.unsafe_get(j))
      re.unsafe_set(j, tr)
      im.unsafe_set(j, ti)
    }
  }
  let mut size : Int32 = 2
  while size <= n {
    let half = size / 2
    let stride = n / size
    let mut start = 0
    while start < n {
      for j in 0..<half {
        let idx1 = start + j
        let idx2 = start + j + half
        let tw_idx = j * stride
        let wr = tw_re.unsafe_get(tw_idx)
        let wi = tw_im.unsafe_get(tw_idx)
        let dr = re.unsafe_get(idx2)
        let di = im.unsafe_get(idx2)
        let tr = wr * dr - wi * di
        let ti = wr * di + wi * dr
        let or_ = re.unsafe_get(idx1)
        let oi = im.unsafe_get(idx1)
        re.unsafe_set(idx1, or_ + tr)
        im.unsafe_set(idx1, oi + ti)
        re.unsafe_set(idx2, or_ - tr)
        im.unsafe_set(idx2, oi - ti)
      }
      start += size
    }
    size *= 2
  }
}

// =============================================================================
// Inline Tests
// =============================================================================

///|
test "Complex::mag computes correct magnitude" {
  let z = Complex::{ re: 3.0, im: 4.0, }
  assert_eq(z.mag(), 5.0)
}

///|
test "Complex::add adds correctly" {
  let a = Complex::{ re: 1.0, im: 2.0, }
  let b = Complex::{ re: 3.0, im: 4.0, }
  let c = a.add(b)
  assert_eq(c.re, 4.0)
  assert_eq(c.im, 6.0)
}

///|
test "Complex::mul multiplies correctly" {
  let a = Complex::{ re: 1.0, im: 2.0, }
  let b = Complex::{ re: 3.0, im: 4.0, }
  let c = a.mul(b)
  assert_eq(c.re, -5.0)
  assert_eq(c.im, 10.0)
}

///|
test "Complex::scale scales correctly" {
  let z = Complex::{ re: 2.0, im: 4.0, }
  let s = z.scale(0.5)
  assert_eq(s.re, 1.0)
  assert_eq(s.im, 2.0)
}

///|
test "bit_reverse reverses bits correctly" {
  assert_eq(bit_reverse(0b001, 3), 0b100)
  assert_eq(bit_reverse(0b101, 3), 0b101)
  assert_eq(bit_reverse(0b000, 3), 0b000)
  assert_eq(bit_reverse(0b111, 3), 0b111)
}

///|
test "log2_int computes log2 of powers of 2" {
  assert_eq(log2_int(1), 0)
  assert_eq(log2_int(2), 1)
  assert_eq(log2_int(4), 2)
  assert_eq(log2_int(8), 3)
  assert_eq(log2_int(1024), 10)
}

///|
test "FFT of DC signal produces single peak at bin 0" {
  let n = 8
  let data = Array::make(n, Complex::{ re: 1.0, im: 0.0, })
  fft(data)
  assert_true(data[0].mag() > 7.9)
  for i in 1..<n {
    assert_true(data[i].mag() < 0.1)
  }
}

///|
test "FFT of pure sine wave produces two peaks" {
  let n = 8
  let freq = 2
  let data = Array::makei(n, fn(i) {
    Complex::{
      re: @math.sin(
        2.0 * @math.PI * freq.to_double() * i.to_double() / n.to_double(),
      ),
      im: 0.0,
    }
  })
  fft(data)
  assert_true(data[freq].mag() > 1.0)
  assert_true(data[n - freq].mag() > 1.0)
  assert_true(data[0].mag() < 0.1)
}

///|
test "SoA FFT matches Complex FFT on DC signal" {
  let n = 8
  let bits = log2_int(n)
  let (tw_re, tw_im) = precompute_twiddles_soa(n)
  let re = Array::make(n, 1.0)
  let im = Array::make(n, 0.0)
  let bit_rev = precompute_bit_reversal(n, bits)
  fft_soa(re, im, tw_re, tw_im, bit_rev)
  let mag0 = (re[0] * re[0] + im[0] * im[0]).sqrt()
  assert_true(mag0 > 7.9)
  for i in 1..<n {
    let mag = (re[i] * re[i] + im[i] * im[i]).sqrt()
    assert_true(mag < 0.1)
  }
}

///|
test "SoA FFT matches Complex FFT on sine wave" {
  let n = 16
  let freq = 3
  let bits = log2_int(n)
  let (tw_re, tw_im) = precompute_twiddles_soa(n)
  let re_soa = Array::makei(n, fn(i) {
    @math.sin(2.0 * @math.PI * freq.to_double() * i.to_double() / n.to_double())
  })
  let im_soa = Array::make(n, 0.0)
  let bit_rev = precompute_bit_reversal(n, bits)
  fft_soa(re_soa, im_soa, tw_re, tw_im, bit_rev)
  let mag_f = (re_soa[freq] * re_soa[freq] + im_soa[freq] * im_soa[freq]).sqrt()
  let mag_nf = (re_soa[n - freq] * re_soa[n - freq] +
  im_soa[n - freq] * im_soa[n - freq]).sqrt()
  assert_true(mag_f > 1.0)
  assert_true(mag_nf > 1.0)
  let mag_dc = (re_soa[0] * re_soa[0] + im_soa[0] * im_soa[0]).sqrt()
  assert_true(mag_dc < 0.1)
}

///|
test "SoA Hann window produces correct endpoints" {
  let n = 1024
  let hann = precompute_hann_window(n)
  assert_true(hann[0] < 0.001)
  assert_true(hann[n - 1] < 0.001)
  assert_true((hann[n / 2] - 1.0).abs() < 0.001)
}

///|
test "Complex Hann window tapers endpoints" {
  let n = 16
  let data = Array::make(n, Complex::{ re: 1.0, im: 0.0, })
  apply_hann_window(data)
  assert_true(data[0].re < 0.1)
  assert_true(data[n - 1].re < 0.1)
  assert_true(data[n / 2].re > 0.9)
}
