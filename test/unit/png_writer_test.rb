# frozen_string_literal: true

require_relative "../test_helper"
require "zlib"

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
      assert_includes content, "IHDR"
    end
  end

  def test_ihdr_contains_correct_dimensions
    image = Array.new(99) { Array.new(42) { [50, 100, 150] } }

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(42, 99)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      ihdr_idx = content.index("IHDR")
      ihdr_data = content[ihdr_idx + 4, 13]
      width, height = ihdr_data.unpack("NN")

      assert_equal 42, width
      assert_equal 99, height
    end
  end

  def test_ihdr_color_type_is_rgb
    image = [[[0, 0, 0]]]

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(1, 1)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      ihdr_idx = content.index("IHDR")
      ihdr_data = content[ihdr_idx + 4, 13]
      _, _, _, color_type = ihdr_data.unpack("NNCCCC")

      assert_equal 2, color_type
    end
  end

  def test_idat_chunk_present
    image = [[[100, 200, 150]]]

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(1, 1)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      assert_includes content, "IDAT"
    end
  end

  def test_iend_chunk_present
    image = [[[100, 200, 150]]]

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(1, 1)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      assert_includes content, "IEND"
    end
  end

  def test_pixel_data_roundtrip
    image = [
      [[10, 20, 30], [40, 50, 60]],
      [[70, 80, 90], [100, 110, 120]]
    ]

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(2, 2)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      idat_idx = content.index("IDAT")
      idat_length = content[idat_idx - 4, 4].unpack("N")[0]
      compressed = content[idat_idx + 4, idat_length]

      raw = Zlib::Inflate.inflate(compressed)

      assert_equal 2 * (1 + 2 * 3), raw.bytesize

      pixel_0_0 = raw[1, 3]
      assert_equal [10, 20, 30].pack("C3"), pixel_0_0

      pixel_0_1 = raw[4, 3]
      assert_equal [40, 50, 60].pack("C3"), pixel_0_1

      pixel_1_0 = raw[8, 3]
      assert_equal [70, 80, 90].pack("C3"), pixel_1_0

      pixel_1_1 = raw[11, 3]
      assert_equal [100, 110, 120].pack("C3"), pixel_1_1
    end
  end

  def test_non_square_image
    image = Array.new(3) { Array.new(5) { [255, 0, 0] } }

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(5, 3)
      writer.set_image_data(image)
      writer.write(output)

      content = File.read(output, mode: "rb")
      ihdr_idx = content.index("IHDR")
      ihdr_data = content[ihdr_idx + 4, 13]
      width, height = ihdr_data.unpack("NN")

      assert_equal 5, width
      assert_equal 3, height
    end
  end

  def test_single_pixel
    image = [[[0, 0, 0]]]

    Dir.mktmpdir do |dir|
      output = File.join(dir, "test.png")

      writer = KDC::PNGWriter.new(1, 1)
      writer.set_image_data(image)
      writer.write(output)

      assert File.exist?(output)
      assert File.size(output) > 0
    end
  end
end
