# frozen_string_literal: true

require_relative "../test_helper"

class StuckPixelTest < Minitest::Test
  def test_rgb_no_stuck_pixels
    # Uniform image — no pixels should be modified
    pixels = Array.new(4) { 0xFF_80_80_80 } # 2x2
    result = KDC::StuckPixel.fix_rgb(pixels, 2, 2)
    assert_equal pixels, result
  end

  def test_rgb_detects_obvious_stuck_pixel
    # 3x3 image, center pixel way off from neighbors
    # Neighbors vary with R range > MIN_RANGE=15 so stuck check triggers
    n1 = (80 << 16) | (128 << 8) | 128   # R=80
    n2 = (100 << 16) | (128 << 8) | 128  # R=100
    n3 = (120 << 16) | (128 << 8) | 128  # R=120 (range=40 > 15)
    center = (0 << 16) | (128 << 8) | 128 # R=0 is way off
    pixels = [
      n1, n2, n3,
      n2, center, n1,
      n3, n2, n1
    ]
    result = KDC::StuckPixel.fix_rgb(pixels, 3, 3)

    center_result = result[4]
    cr = (center_result >> 16) & 0xFF
    refute_equal 0, cr, "R should be corrected from 0"
    assert cr >= 80, "R should be near neighbor values"
  end

  def test_rgb_small_image_unchanged
    pixels = [0xFF_80_80_80] * 4
    result = KDC::StuckPixel.fix_rgb(pixels, 2, 2)
    assert_equal pixels, result
  end

  def test_bayer_2d_no_stuck_pixels
    bayer = Array.new(6) { Array.new(6, 100) }
    result = KDC::StuckPixel.fix_bayer_2d(bayer)
    assert_equal bayer, result
  end

  def test_bayer_2d_detects_stuck_pixel
    bayer = Array.new(6) { Array.new(6, 100) }
    bayer[2][2] = 10000 # Stuck pixel — way off from same-color neighbors

    result = KDC::StuckPixel.fix_bayer_2d(bayer)
    # The stuck pixel should be replaced
    refute_equal 10000, result[2][2], "Stuck pixel should be replaced"
    assert result[2][2] < 500, "Replacement should be near neighbor value"
  end

  def test_bayer_2d_small_image_unchanged
    bayer = Array.new(4) { Array.new(4, 100) }
    result = KDC::StuckPixel.fix_bayer_2d(bayer)
    assert_equal bayer, result
  end

  def test_bayer_flat_no_stuck_pixels
    raw = Array.new(36, 100)
    result = KDC::StuckPixel.fix_bayer_flat(raw, 6, 6)
    assert_equal raw, result
  end

  def test_bayer_flat_detects_stuck_pixel
    raw = Array.new(36, 100)
    raw[14] = 10000 # (row 2, col 2) stuck

    result = KDC::StuckPixel.fix_bayer_flat(raw, 6, 6)
    refute_equal 10000, result[14], "Stuck pixel should be replaced"
  end

  def test_bayer_flat_small_image_unchanged
    raw = Array.new(16, 100)
    result = KDC::StuckPixel.fix_bayer_flat(raw, 4, 4)
    assert_equal raw, result
  end
end
