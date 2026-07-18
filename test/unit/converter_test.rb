# frozen_string_literal: true

require_relative "../test_helper"

class ConverterTest < Minitest::Test
  include TestHelper

  def test_convert_returns_image
    converter = KDC::Converter.new(kdc_path("DC120-flash-raw.kdc"), color_lut: nil, remove_stuck_pixels: false)
    image = converter.convert

    assert_instance_of Array, image
    assert_equal 976, image.length
    assert_equal 1301, image[0].length
  end

  def test_convert_to_tiff
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :tif) do |output|
      assert File.exist?(output)
      assert File.size(output) > 0
    end
  end

  def test_convert_to_png
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :png) do |output|
      assert File.exist?(output)
      assert File.size(output) > 0
    end
  end

  def test_scale_to_16bit
    converter = KDC::Converter.new(kdc_path("DC120-flash-raw.kdc"), color_lut: nil, remove_stuck_pixels: false)
    converter.instance_variable_set(:@demosaiced_image, [[[100, 200, 300]]])
    converter.send(:scale_to_16bit)

    r, g, b = converter.demosaiced_image[0][0]
    assert r > 100, "R should be scaled up"
    assert g > 200, "G should be scaled up"
    assert b > 300, "B should be scaled up"
  end

  def test_resize_bilinear
    converter = KDC::Converter.new(kdc_path("DC120-flash-raw.kdc"), color_lut: nil, remove_stuck_pixels: false)

    image = Array.new(10) { Array.new(10) { [100, 200, 150] } }
    result = converter.send(:resize_bilinear, image, 20, 20)

    assert_equal 20, result.length
    assert_equal 20, result[0].length
  end

  # Tests for extracted modules

  def test_resize_module_bilinear
    image = Array.new(10) { Array.new(10) { [100, 200, 150] } }
    result = KDC::Resize.bilinear(image, 20, 20)

    assert_equal 20, result.length
    assert_equal 20, result[0].length
    assert_equal [100, 200, 150], result[0][0]
  end

  def test_scale_module_to_8bit
    image = [[[256, 512, 1024]]]
    result = KDC::Scale.to_8bit(image)

    # >> 8 truncates: 256>>8=1, 512>>8=2, 1024>>8=4
    assert_equal [[[1, 2, 4]]], result
  end

  def test_scale_module_to_16bit
    image = [[[100, 200, 300]]]
    result = KDC::Scale.to_16bit(image, 255)

    # 100 * 65535 / 255 = 25700
    assert_equal 25700, result[0][0][0]
    assert_equal 51400, result[0][0][1]
  end

  def test_scale_module_in_place
    image = [[[100, 200, 300]]]
    KDC::Scale.scale_16bit_in_place!(image, 255)

    assert_equal 25700, image[0][0][0]
    assert_equal 51400, image[0][0][1]
  end

  def test_dc50_processing_matrix
    image = [[[1000, 2000, 500]]]
    result = KDC::DC50Processing.apply_matrix(image)

    # Matrix should transform the values
    refute_equal image[0][0], result[0][0]
    # All channels should be non-negative (clamped)
    result[0][0].each { |v| assert v >= 0, "Channel value should be non-negative" }
  end
end
