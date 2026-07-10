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
end
