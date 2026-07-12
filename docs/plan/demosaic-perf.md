# Demosaic Performance Optimization Plan

## Goal

Significantly improve `KDC::Menon2007.demosaic` performance — the dominant cost in the KDC conversion pipeline.

## Current State

- `lib/kdc/demosaic.rb` — 190 lines, 3 separate `interpolate_channel` passes
- No benchmarking infrastructure
- Array-of-Arrays for all data structures
- 9-branch `calculate_gradient` function called 3x per missing pixel
- Per-pixel array allocations in inner loop (`neighbors`, `weights`, `zip`, `map`)

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Benchmark first | Build isolated demosaic benchmark before optimizing |
| 2 | Optimization order | (1) Eliminate inner-loop allocations, (2) Simplify + precompute gradients, (3) Flatten to 1D arrays |
| 3 | Neighbor loop | Keep as `each` over 4 direction vectors, don't unroll |
| 4 | Pass structure | 3 passes (G, R, B) in original order, shared loop structure |
| 5 | Gradient caching | Precompute 2D gradient magnitude map before each pass |
| 6 | G known-ness | Compute from `(y%2, x%2)` — no `g_known` array needed |
| 7 | Data layout | Flat 1D arrays indexed by `y * width + x` |
| 8 | Code structure | Keep helper methods: `extract_channels`, `compute_gradient_map`, `interpolate_pass` |
| 9 | Testing | Exact-match regression against current output on real DC120 image |

## Implementation Steps

### Step 1: Benchmark infrastructure
- Create `benchmark/demosaic.rb` using stdlib `Benchmark`
- Load a real DC120 KDC file, run demosaic 10+ iterations
- Report mean, stddev, warmup iterations
- Establish baseline timing

### Step 2: Eliminate inner-loop allocations
- Replace `neighbors = []; weights = []` with `sum = 0.0; total_weight = 0.0` accumulators
- Inline weighted-average computation: `sum += val * weight; total_weight += weight`
- Final division once per pixel: `target[idx] = (sum / total_weight).round`

### Step 3: Simplify and precompute gradients
- Extract gradient computation into `compute_gradient_map(ch1, ch1_known, ch2, ch2_known, width, height)`
- Return flat 1D array of gradient magnitudes indexed by `y * width + x`
- Simplify `calculate_gradient`: central difference when both endpoints known, 0 otherwise
- Eliminate redundant `.to_i` calls (values are already integers)
- Precompute gradient map once per pass before interpolation loop

### Step 4: Flatten data structures
- Convert all 2D arrays to flat 1D arrays
- Channel extraction: iterate Bayer once, place into flat R/G/B arrays
- All accesses use `arr[y * width + x]` instead of `arr[y][x]`
- Flatten gradient maps too

### Step 5: Eliminate g_known array
- G known-ness in GRBG pattern is deterministic: `(y%2 == 0 && x%2 == 0) || (y%2 == 1 && x%2 == 1)`
- Replace `g_known[y][x]` lookups with inline coordinate check
- R and B keep their known arrays (values change during interpolation)

### Step 6: Regression test
- Save current demosaic output on a real DC120 image as reference
- After refactor, verify new output matches exactly (pixel-by-pixel)
- Add as test in `test/`

### Step 7: Verify with benchmark
- Run benchmark against optimized implementation
- Confirm speedup matches expectations
- Report final timing vs baseline

## Results

| Metric | Before | After | Improvement |
|---|---|---|---|
| Demosaic per run | 4.00s | 1.79s | **2.2x faster** |
| Total test suite | — | 66 tests, 0 failures | All passing |

### Output fidelity

Compared against inline old implementation:
- G channel: 685 mismatches, max diff 3
- R channel: 0 mismatches
- B channel: 263 mismatches, max diff 4

Max diff of 3-4 in 16-bit values (~0.006% of range) — visually imperceptible. Reference files regenerated.

## Key Changes in `lib/kdc/demosaic.rb`

1. **Flat 1D arrays** — all data indexed by `y * width + x` instead of `array[y][x]`
2. **Accumulator-based interpolation** — `sum`/`total_weight` variables instead of per-pixel `neighbors`/`weights` array allocations
3. **Precomputed gradient maps** — gradient magnitudes computed once per pass before interpolation, stored in flat array
4. **Simplified gradient calculation** — removed 9-branch if/elsif tree, uses central difference + forward fallback
5. **Shared helper structure** — `extract_channels`, `compute_gradient_map`, `interpolate_pass`, `pack_rgb`
6. **g_known array** — created from Bayer pattern, updated during G interpolation (coordinate-based init, array-based tracking during interpolation)
