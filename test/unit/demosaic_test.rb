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
end
