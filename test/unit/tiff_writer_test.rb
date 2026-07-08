# frozen_string_literal: true

require_relative "../test_helper"

class TIFFWriterTest < Minitest::Test
  def test_write_creates_valid_tiff
    image = [
      [[100, 200, 150], [180, 120, 220]],
      [[140, 240, 170], [200, 130, 230]]
    ]
    
    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.tif")
      
      writer = KDC::TIFFWriter.new(2, 2)
      writer.set_image_data(image)
      writer.setup_image_info
      writer.write(output)
      
      assert File.exist?(output)
      
      # Check TIFF header
      content = File.read(output, mode: "rb")
      assert_equal "MM".b, content[0, 2]
    end
  end

  def test_camera_info
    image = [[[100, 200, 150]]]
    
    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.tif")
      
      writer = KDC::TIFFWriter.new(1, 1)
      writer.set_image_data(image)
      writer.setup_image_info
      writer.set_camera_info(make: "TestMaker", model: "TestModel")
      writer.write(output)
      
      content = File.read(output)
      assert_includes content, "TestMaker"
      assert_includes content, "TestModel"
    end
  end
end
