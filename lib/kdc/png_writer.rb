# frozen_string_literal: true

require "zlib"

module KDC
  class PNGWriter
    PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C8")

    def initialize(width, height)
      @width = width
      @height = height
    end

    def set_image_data(image_data)
      @image_data = image_data
    end

    def write(output_path)
      pixels = expand_pixels
      validate_pixels(pixels)

      out = String.new(encoding: Encoding::BINARY)
      out << PNG_SIGNATURE
      out << build_ihdr_chunk
      out << build_idat_chunk(pixels)
      out << build_iend_chunk

      File.binwrite(output_path, out)
    end

    private

    def expand_pixels
      height = @height
      width = @width
      stride = width * 3
      total_pixels = height * stride

      # Preallocate output string with exact capacity
      pixels = String.new(encoding: Encoding::BINARY, capacity: total_pixels)
      data = @image_data

      y = 0
      while y < height
        row = data[y]
        x = 0
        idx = 0
        while x < width
          r, g, b = row[x]
          pixels << (r & 0xFF).chr << (g & 0xFF).chr << (b & 0xFF).chr
          x += 1
        end
        y += 1
      end

      pixels
    end

    def validate_pixels(pixels)
      expected = @width * @height * 3
      unless pixels.bytesize == expected
        raise ArgumentError, "pixel data size #{pixels.bytesize} != expected #{expected} (#{@width}x#{@height}x3)"
      end
    end

    def build_ihdr_chunk
      data = [
        @width,
        @height,
        8,  # bit depth
        2,  # color type: RGB
        0,  # compression method
        0,  # filter method
        0   # interlace method
      ].pack("NNC5")
      make_chunk("IHDR", data)
    end

    def build_idat_chunk(pixels)
      raw = build_raw_data(pixels)
      compressed = Zlib::Deflate.deflate(raw, 6)
      make_chunk("IDAT", compressed)
    end

    def build_raw_data(pixels)
      stride = @width * 3
      raw = String.new(encoding: Encoding::BINARY, capacity: @height * (1 + stride))

      y = 0
      while y < @height
        row_start = y * stride
        row = pixels.byteslice(row_start, stride)
        raw << "\x00".b << row
        y += 1
      end

      raw
    end

    def make_chunk(type, data)
      data = data.b
      crc = Zlib.crc32(type + data)
      [data.bytesize].pack("N") + type + data + [crc].pack("N")
    end

    def build_iend_chunk
      make_chunk("IEND", "")
    end
  end
end