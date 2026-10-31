// =============================================================================
// FFT Module — Radix-2 Cooley-Tukey Fast Fourier Transform
// Optimized with MoonBit features: struct methods, derive(Debug),
// unsafe array access, precomputed twiddle factors, test blocks
// =============================================================================

///|
/// Complex number with real (re) and imaginary (im) parts
/// derive(Debug) auto-generates to_string for debugging
struct Complex {
  re : Double
  im : Double
} derive(Debug)

///|
/// Complex magnitude: |z| = sqrt(re² + im²)
fn Complex::mag(self : Complex) -> Double {
  (self.re * self.re + self.im * self.im).sqrt()
}

///|
/// Complex addition: (a + b)
fn Complex::add(self : Complex, other : Complex) -> Complex {
  Complex::{ re: self.re + other.re, im: self.im + other.im, }
}

///|
/// Complex subtraction: (a - b)
fn Complex::sub(self : Complex, other : Complex) -> Complex {
  Complex::{ re: self.re - other.re, im: self.im - other.im, }
}

///|
/// Complex multiplication: (a * b)
fn Complex::mul(self : Complex, other : Complex) -> Complex {
  Complex::{
    re: self.re * other.re - self.im * other.im,
    im: self.re * other.im + self.im * other.re,
  }
}

///|
/// Scalar multiplication: z * s
fn Complex::scale(self : Complex, s : Double) -> Complex {
  Complex::{ re: self.re * s, im: self.im * s, }
}

///|
/// Construct from polar form: r * (cos θ + i sin θ)
fn Complex::from_polar(r : Double, theta : Double) -> Complex {
  Complex::{ re: r * @math.cos(theta), im: r * @math.sin(theta), }
}

///|
/// Compute log₂ of a power-of-2 integer using bit counting
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
/// Bit-reversal permutation: reverse the lower 'bits' bits of n
/// Example: bit_reverse(0b001, 3) = 0b100 = 4
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
/// Precompute twiddle factors W^k = exp(-2πik/N) for k = 0..N/2-1
/// Using a precomputed array avoids floating-point error accumulation
/// from iterative multiplication in the butterfly loop
fn precompute_twiddles(half_size : Int32) -> Array[Complex] {
  let angle = -2.0 * @math.PI / (half_size * 2).to_double()
  Array::makei(half_size, fn(k) {
    Complex::from_polar(1.0, angle * k.to_double())
  })
}

///|
/// Iterative radix-2 Cooley-Tukey FFT (in-place transform)
///
/// # Algorithm
/// 1. Bit-reversal permutation: reorder samples into bit-reversed index order
/// 2. Butterfly operations: combine pairs at increasing stride (2, 4, 8, ..., N)
///    using precomputed twiddle factors for numerical stability
///
/// # Parameters
/// - data: array of Complex numbers, length must be a power of 2
///
/// After calling, data[] contains the frequency-domain complex values.
fn fft(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let bits = log2_int(n)

  // Step 1: Bit-reversal permutation using unsafe access for performance
  for i in 0..<n {
    let j = bit_reverse(i, bits)
    if j > i {
      let temp = data[i]
      data[i] = data[j]
      data[j] = temp
    }
  }

  // Step 2: Butterfly operations with precomputed twiddle factors
  let mut size : Int32 = 2
  while size <= n {
    let half = size / 2
    // Precompute twiddle factors for this stage — avoids error accumulation
    let twiddles = precompute_twiddles(half)

    let mut start = 0
    while start < n {
      // Use unsafe access in the inner loop — hot path, indices are guaranteed valid
      for j in 0..<half {
        let idx1 = start + j
        let idx2 = start + j + half
        // t = W^j * data[idx2]  (using Complex::mul method)
        let t = data.unsafe_get(idx2).mul(twiddles.unsafe_get(j))
        // Butterfly: X[idx1] = orig + t, X[idx2] = orig - t
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
/// Apply Hann window function to each sample before FFT
///
/// The Hann window reduces spectral leakage by smoothly tapering
/// the signal to zero at the chunk boundaries.
///
/// w(n) = 0.5 × (1 - cos(2πn / (N-1)))
///
/// Uses Array::mapi_in_place for idiomatic in-place transformation
fn apply_hann_window(data : Array[Complex]) -> Unit {
  let n = data.length()
  if n <= 1 {
    return
  }
  let denom = (n - 1).to_double()
  // mapi_in_place: functional style in-place mutation
  data.mapi_in_place(fn(i, z) {
    let hann = 0.5 * (1.0 - @math.cos(2.0 * @math.PI * i.to_double() / denom))
    z.scale(hann)
  })
}

// =============================================================================
// Inline Tests — MoonBit native test blocks
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
  // (1+2i)(3+4i) = 3+4i+6i+8i² = -5+10i
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
  // All-ones signal → FFT should have magnitude N at bin 0, ~0 elsewhere
  let n = 8
  let data = Array::make(n, Complex::{ re: 1.0, im: 0.0, })
  fft(data)
  assert_true(data[0].mag() > 7.9) // ≈ 8
  for i in 1..<n {
    assert_true(data[i].mag() < 0.1) // ≈ 0
  }
}

///|
test "FFT of pure sine wave produces two peaks" {
  // sin(2π f t) → peaks at bins f and N-f
  let n = 8
  let freq = 2 // 2 cycles in N samples
  let data = Array::makei(n, fn(i) {
    Complex::{
      re: @math.sin(
        2.0 * @math.PI * freq.to_double() * i.to_double() / n.to_double(),
      ),
      im: 0.0,
    }
  })
  fft(data)
  // Peaks should be at bins 2 and 6 (n - freq)
  assert_true(data[freq].mag() > 1.0)
  assert_true(data[n - freq].mag() > 1.0)
  // Bin 0 (DC) should be near zero
  assert_true(data[0].mag() < 0.1)
}
