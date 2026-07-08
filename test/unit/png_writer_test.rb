# frozen_string_literal: true

require_relative "../test_helper"

class PNGWriterTest < Minitest::Test
  def test_write_creates_valid_png
    image = [
      [[100, 200, 150], [180, 120, 220]],
      [[140, 240, 170], [200, 130, 230]]
    ]
    
    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")
      
      writer = KDC::PNGWriter.new(2, 2)
      writer.set_image_data(image)
      writer.write(output)
      
      assert File.exist?(output)
      
      # Check PNG signature
      content = File.read(output, mode: "rb")
      assert_equal "\x89PNG\r\n\x1a\n".b, content[0, 8]
    end
  end

  def test_ihdr_chunk_present
    image = [[[100, 200, 150]]]
    
    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")
      
      writer = KDC::PNGWriter.new(1, 1)
      writer.set_image_data(image)
      writer.write(output)
      
      content = File.read(output, mode: "rb")
      
      # IHDR chunk should be present (after signature)
      assert content.include?("IHDR".b)
    end
  end

  def test_output_dimensions
    image = Array.new(10) { Array.new(20) { [100, 200, 150] } }
    
    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")
      
      writer = KDC::PNGWriter.new(20, 10)
      writer.set_image_data(image)
      writer.write(output)
      
      # Use file command to verify
      result = `file #{output}`
      assert_match(/20 x 10/, result)
    end
  end
end
