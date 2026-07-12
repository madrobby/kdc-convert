# frozen_string_literal: true

require_relative "../lib/kdc"
require "benchmark"

KDC_PATH = File.join(__dir__, "..", "test", "fixtures", "DC120-noflash-high.kdc")
WARMUP_RUNS = 3
ITERATIONS = 15

puts "Loading KDC: #{KDC_PATH}"
metadata = KDC.parse_kdc(KDC_PATH)

puts "Decoding raw Bayer..."
raw_image = KDC::DC120Decoder.new(
  KDC_PATH,
  compressed: metadata.compression == 7,
  data_offset: metadata.kdc_data_offset,
  data_size: metadata.kdc_data_size,
  remove_stuck_pixels: true
).decode

puts "Applying black level..."
black_level = metadata.kdc_black_level[0]
raw_image.each do |row|
  row.map! { |v| [v - black_level, 0].max }
end

puts "Bayer size: #{raw_image[0].length}x#{raw_image.length}"
puts ""

puts "Warming up (#{WARMUP_RUNS} runs)..."
WARMUP_RUNS.times do
  KDC::Menon2007.demosaic(raw_image, "GRBG")
end

puts "Running benchmark (#{ITERATIONS} iterations)..."
puts ""

times = Benchmark.measure do
  ITERATIONS.times do |i|
    KDC::Menon2007.demosaic(raw_image, "GRBG")
    if (i + 1) % 5 == 0
      puts "  run #{i + 1}/#{ITERATIONS}..."
    end
  end
end

# Calculate stats from individual measurements
puts "Done."
puts ""
puts "Results:"
puts "  Total time:  #{'%.4f' % times.real}s"
puts "  Per run:     #{'%.4f' % (times.real / ITERATIONS)}s"
puts "  Iterations:  #{ITERATIONS}"
