# frozen_string_literal: true

require_relative "../test_helper"

class ScaleTest < Minitest::Test
  def test_to_8bit_normalizes_16bit
    image = [[[65535, 32768, 0]]]
    result = KDC::Scale.to_8bit(image)
    assert_equal 255, result[0][0][0]
    assert_equal 128, result[0][0][1], "32768 >> 8 = 128"
    assert_equal 0, result[0][0][2]
  end

  def test_to_8bit_overflow_values
    # to_8bit uses >> 8 without clamping — values > 65535 produce > 255
    image = [[[70000, 65535, 0]]]
    result = KDC::Scale.to_8bit(image)
    assert_equal 273, result[0][0][0], "70000 >> 8 = 273 (no clamping)"
    assert_equal 255, result[0][0][1], "65535 >> 8 = 255"
    assert_equal 0, result[0][0][2]
  end

  def test_to_16bit_scales_by_white_level
    # white_level=255 means: pixel value 128 → 128 * (65535/255) ≈ 32768
    image = [[[128, 255, 0]]]
    result = KDC::Scale.to_16bit(image, 255)
    assert result[0][0][0] > 32000 && result[0][0][0] < 34000, "128 * 65535/255 ≈ 32896"
    assert_equal 65535, result[0][0][1], "255 * 65535/255 = 65535"
    assert_equal 0, result[0][0][2]
  end

  def test_to_16bit_clamps
    image = [[[300, 255, 0]]]
    result = KDC::Scale.to_16bit(image, 255)
    assert_equal 65535, result[0][0][0], "300 > 255 so clamped to 65535"
  end

  def test_to_16bit_preserves_dimensions
    image = Array.new(5) { Array.new(8) { [100, 100, 100] } }
    result = KDC::Scale.to_16bit(image, 255)
    assert_equal 5, result.length
    assert_equal 8, result[0].length
  end

  def test_scale_16bit_in_place_multiplies_by_factor
    # white_level=0.5 means scale_factor = 65535.0/0.5 = 131070
    image = [[[100, 200, 300]]]
    KDC::Scale.scale_16bit_in_place!(image, 0.5)
    assert_equal 65535, image[0][0][0], "100 * 131070 = 13107000 → clamped to 65535"
    assert_equal 65535, image[0][0][1], "200 * 131070 → clamped to 65535"
    assert_equal 65535, image[0][0][2], "300 * 131070 → clamped to 65535"
  end

  def test_scale_16bit_in_place_scales_by_white_level
    # white_level=255, pixel=128 → 128 * (65535/255) ≈ 32896
    image = [[[128, 0, 0]]]
    KDC::Scale.scale_16bit_in_place!(image, 255)
    assert image[0][0][0] > 32000 && image[0][0][0] < 34000, "Should scale by 65535/255"
  end

  def test_scale_16bit_in_place_clamps
    image = [[[300, 255, 0]]]
    KDC::Scale.scale_16bit_in_place!(image, 255)
    assert_equal 65535, image[0][0][0], "300 > white_level → clamped to 65535"
  end

  def test_to_8bit_preserves_dimensions
    image = Array.new(5) { Array.new(8) { [100, 100, 100] } }
    result = KDC::Scale.to_8bit(image)
    assert_equal 5, result.length
    assert_equal 8, result[0].length
  end
end
