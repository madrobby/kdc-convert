# frozen_string_literal: true

require_relative "../test_helper"

class ConverterTest < Minitest::Test
  include TestHelper

  def test_convert_returns_image
    converter = KDC::Converter.new(image_path("DC120_1.KDC"), color_lut: nil)
    image = converter.convert
    
    assert_instance_of Array, image
    assert_equal 976, image.length
    assert_equal 1301, image[0].length
  end

  def test_convert_to_tiff
    convert_to_temp(image_path("DC120_1.KDC"), format: :tif) do |output|
      assert File.exist?(output)
      assert File.size(output) > 0
    end
  end

  def test_convert_to_png
    convert_to_temp(image_path("DC120_1.KDC"), format: :png) do |output|
      assert File.exist?(output)
      assert File.size(output) > 0
    end
  end

  def test_scale_to_16bit
    converter = KDC::Converter.new(image_path("DC120_1.KDC"), color_lut: nil)
    converter.instance_variable_set(:@demosaiced_image, [[[100, 200, 300]]])
    converter.send(:scale_to_16bit)
    
    r, g, b = converter.demosaiced_image[0][0]
    assert r > 100, "R should be scaled up"
    assert g > 200, "G should be scaled up"
    assert b > 300, "B should be scaled up"
  end

  def test_resize_bilinear
    converter = KDC::Converter.new(image_path("DC120_1.KDC"), color_lut: nil)
    
    image = Array.new(10) { Array.new(10) { [100, 200, 150] } }
    result = converter.send(:resize_bilinear, image, 20, 20)
    
    assert_equal 20, result.length
    assert_equal 20, result[0].length
  end
end
