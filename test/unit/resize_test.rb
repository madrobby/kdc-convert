# frozen_string_literal: true

require_relative "../test_helper"

class ResizeTest < Minitest::Test
  def test_bilinear_upscale
    image = Array.new(10) { Array.new(10) { [100, 200, 150] } }
    result = KDC::Resize.bilinear(image, 20, 20)

    assert_equal 20, result.length
    assert_equal 20, result[0].length
    # Uniform image should produce uniform output
    assert_equal [100, 200, 150], result[0][0]
    assert_equal [100, 200, 150], result[19][19]
  end

  def test_bilinear_downscale
    image = Array.new(20) { Array.new(20) { [300, 400, 500] } }
    result = KDC::Resize.bilinear(image, 10, 10)

    assert_equal 10, result.length
    assert_equal 10, result[0].length
    assert_equal [300, 400, 500], result[0][0]
  end

  def test_bilinear_clamps_at_65535
    # Values at max should stay at max
    image = Array.new(10) { Array.new(10) { [65535, 65535, 65535] } }
    result = KDC::Resize.bilinear(image, 20, 20)
    result.each do |row|
      row.each do |pixel|
        pixel.each { |v| assert v <= 65535, "Should not exceed 65535" }
      end
    end
  end

  def test_bilinear_single_pixel
    image = [[[100, 200, 300]]]
    result = KDC::Resize.bilinear(image, 2, 2)
    assert_equal 2, result.length
    assert_equal 2, result[0].length
  end

  def test_bilinear_preserves_dimensions
    image = Array.new(5) { Array.new(8) { [100, 100, 100] } }
    result = KDC::Resize.bilinear(image, 16, 10)
    assert_equal 10, result.length
    assert_equal 16, result[0].length
  end
end
