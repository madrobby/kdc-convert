# frozen_string_literal: true

# Benchmark: resize_bilinear with correctness verification
# Loads a real 848×976 decoded image, benchmarks the resize step,
# and verifies output matches the baseline golden reference.

require "json"
require_relative "../lib/kdc"

KDC_PATH       = File.join(__dir__, "..", "test", "fixtures", "DC120-flash-raw.kdc")
GOLDEN_REF_PATH = File.join(__dir__, "golden_reference.json")
ITERATIONS     = 7

# Golden reference sample points [ty, tx]
SAMPLE_COORDS = [
  [0, 0],       # top-left
  [0, 1300],    # top-right
  [975, 0],     # bottom-left
  [975, 1300],  # bottom-right
  [487, 650],   # center
  [0, 650],     # top-mid
  [975, 650],   # bottom-mid
  [487, 0],     # mid-left
  [487, 1300],  # mid-right
].freeze

def prepare_decoded_image
  converter = KDC::Converter.new(KDC_PATH, color_lut: nil, remove_stuck_pixels: false)
  converter.send(:parse_metadata)
  converter.send(:decode_raw)
  converter.send(:apply_black_level)
  converter.send(:demosaic_image)
  converter.send(:scale_to_16bit)

  src_width  = converter.demosaiced_image[0].length
  src_height = converter.demosaiced_image.length

  target_height = KDC::Converter::OUTPUT_HEIGHT
  target_width  = (src_width * converter.metadata.kdc_pixel_aspect).round

  puts "Decoded image:  #{src_width}×#{src_height}"
  puts "Resize target:  #{target_width}×#{target_height}"
  puts "Iterations:     #{ITERATIONS}"
  puts ""

  [converter, target_width, target_height]
end

def capture_current(converter, target_width, target_height)
  result = converter.send(:resize_bilinear, converter.demosaiced_image, target_width, target_height)

  ref = {}
  SAMPLE_COORDS.each do |ty, tx|
    r, g, b = result[ty][tx]
    ref["#{ty},#{tx}"] = { r: r, g: g, b: b }
  end

  ref
end

def verify_against_baseline(current_ref)
  baseline = JSON.parse(File.read(GOLDEN_REF_PATH), symbolize_names: true)
  baseline_pixels = baseline[:sample_pixels]

  max_diff = 0
  mismatches = []

  current_ref.each do |coord, current|
    expected = baseline_pixels[coord.to_sym]
    %i[r g b].each do |ch|
      diff = (current[ch] - expected[ch]).abs
      max_diff = diff if diff > max_diff
      mismatches << { coord: coord, channel: ch, expected: expected[ch], actual: current[ch], diff: diff } if diff > 0
    end
  end

  puts "Correctness check:"
  puts "  Max pixel difference: #{max_diff}"
  if mismatches.empty?
    puts "  PASS — all 9 sample pixels match baseline exactly"
  else
    puts "  FAIL — #{mismatches.size} channel(s) differ"
    mismatches.each { |m| puts "    #{m[:coord]} #{m[:channel]}: expected #{m[:expected]}, got #{m[:actual]} (diff #{m[:diff]})" }
  end
  puts ""
  mismatches.empty?
end

def run_benchmark(converter, target_width, target_height)
  times = []

  ITERATIONS.times do |i|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    converter.send(:resize_bilinear, converter.demosaiced_image, target_width, target_height)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    times << elapsed
    puts "  Run #{i + 1}/#{ITERATIONS}: #{(elapsed * 1000).round(2)} ms"
  end

  times
end

def report(times, baseline_mean)
  mean = times.sum / times.size
  sorted = times.sort
  median = sorted[sorted.size / 2]
  stddev = Math.sqrt(times.map { |t| (t - mean) ** 2 }.sum / times.size)

  puts ""
  puts "Results (ms):"
  puts "  Mean:   #{(mean * 1000).round(2)}"
  puts "  Median: #{(median * 1000).round(2)}"
  puts "  Min:    #{(sorted.first * 1000).round(2)}"
  puts "  Max:    #{(sorted.last * 1000).round(2)}"
  puts "  StdDev: #{(stddev * 1000).round(2)}"
  puts ""

  if baseline_mean
    speedup = baseline_mean / mean
    reduction = (1.0 - mean / baseline_mean) * 100
    puts "  Baseline mean: #{(baseline_mean * 1000).round(2)} ms"
    puts "  Speedup:       #{speedup.round(2)}×"
    puts "  Reduction:     #{reduction.round(1)}%"
    puts ""
  end

  { mean: mean, median: median, min: sorted.first, max: sorted.last, stddev: stddev }
end

# --- Main ---
puts "=== resize_bilinear benchmark ==="
puts ""

converter, tw, th = prepare_decoded_image

# Load baseline timing from saved reference
baseline = JSON.parse(File.read(GOLDEN_REF_PATH), symbolize_names: true)
baseline_mean = baseline[:stats][:mean]

puts "Capturing current output for correctness check..."
current_ref = capture_current(converter, tw, th)
puts ""

correct = verify_against_baseline(current_ref)

puts "Running benchmark..."
times = run_benchmark(converter, tw, th)
stats = report(times, baseline_mean)

puts correct ? "All checks passed." : "WARNING: correctness check failed!"
