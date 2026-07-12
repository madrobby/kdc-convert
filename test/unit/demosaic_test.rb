# frozen_string_literal: true

require_relative "../test_helper"

class DemosaicTest < Minitest::Test
  def test_demosaic_returns_rgb_array
    # Create a simple 4x4 Bayer pattern (GRBG)
    bayer = [
      [100, 200, 150, 250],
      [180, 120, 220, 160],
      [140, 240, 170, 270],
      [200, 130, 230, 180]
    ]
    
    rgb = KDC::Menon2007.demosaic(bayer, "GRBG")
    
    assert_instance_of Array, rgb
    assert_equal 4, rgb.length
    assert_equal 4, rgb[0].length
  end

  def test_demosaic_rgb_channels
    bayer = [
      [100, 200],
      [180, 120]
    ]
    
    rgb = KDC::Menon2007.demosaic(bayer, "GRBG")
    
    # Each pixel should be [r, g, b]
    r, g, b = rgb[0][0]
    assert_instance_of Integer, r
    assert_instance_of Integer, g
    assert_instance_of Integer, b
  end

  def test_demosaic_values_reasonable
    bayer = Array.new(10) { Array.new(10) { rand(1000) } }
    
    rgb = KDC::Menon2007.demosaic(bayer, "GRBG")
    
    # All values should be non-negative
    rgb.each do |row|
      row.each do |r, g, b|
        assert r >= 0, "R should be >= 0"
        assert g >= 0, "G should be >= 0"
        assert b >= 0, "B should be >= 0"
      end
    end
  end

  def test_demosaic_regression_real_image
    kdc_path = File.join(__dir__, "..", "fixtures", "DC120-noflash-high.kdc")
    skip "KDC fixture not found" unless File.exist?(kdc_path)

    metadata = KDC.parse_kdc(kdc_path)
    raw = KDC::DC120Decoder.new(
      kdc_path,
      compressed: metadata.compression == 7,
      data_offset: metadata.kdc_data_offset,
      data_size: metadata.kdc_data_size,
      remove_stuck_pixels: true
    ).decode

    black_level = metadata.kdc_black_level[0]
    raw.each { |row| row.map! { |v| [v - black_level, 0].max } }

    rgb = KDC::Menon2007.demosaic(raw, "GRBG")

    ref_path = File.join(__dir__, "..", "fixtures", "demosaic_ref.marshal")
    skip "Regression reference not found" unless File.exist?(ref_path)

    expected = Marshal.load(File.binread(ref_path))

    assert_equal expected.length, rgb.length, "Height mismatch"
    assert_equal expected[0].length, rgb[0].length, "Width mismatch"

    expected.each_with_index do |exp_row, y|
      exp_row.each_with_index do |exp_pixel, x|
        act_pixel = rgb[y][x]
        3.times do |c|
          assert_equal exp_pixel[c], act_pixel[c],
            "Pixel (#{y},#{x}) channel #{c} mismatch: expected #{exp_pixel[c]}, got #{act_pixel[c]}"
        end
      end
    end
  end
end
