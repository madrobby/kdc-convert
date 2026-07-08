# frozen_string_literal: true

require "zlib"

module KDC
  # Write 16-bit RGB PNG files
  class PNGWriter
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

    def initialize(width, height)
      @width = width
      @height = height
      @image_data = nil
    end

    def set_image_data(image_data)
      @image_data = image_data
    end

    def write(output_path)
      chunks = []
      chunks << write_chunk("IHDR", build_ihdr)
      chunks << write_chunk("IDAT", build_idat)
      chunks << write_chunk("IEND", "")

      File.write(output_path, PNG_SIGNATURE + chunks.join)
    end

    private

    def build_ihdr
      # width, height, bit_depth=16, color_type=2 (RGB), compression=0, filter=0, interlace=0
      [@width, @height, 16, 2, 0, 0, 0].pack("NNCCCCC")
    end

    def build_idat
      raw_data = build_raw_scanlines
      Zlib::Deflate.deflate(raw_data, 9)
    end

    def build_raw_scanlines
      height = @image_data.length
      width = @image_data[0].length
      prev_row = nil
      result = "".b

      height.times do |y|
        curr_row = @image_data[y]

        # Build unfiltered row: [R, G, B, R, G, B, ...] as 16-bit big-endian
        unfiltered = "".b
        curr_row.each do |r, g, b|
          unfiltered += [r, g, b].pack("n*")
        end

        # Apply Paeth filter
        filtered = apply_paeth_filter(unfiltered, prev_row, width * 3)

        # Prepend filter byte (4 = Paeth)
        result << [4].pack("C")
        result << filtered

        prev_row = unfiltered
      end

      result
    end

    def apply_paeth_filter(current, prev, row_bytes)
      return current.dup if prev.nil?

      curr = current.bytes.dup
      prev = prev.bytes

      # Process in 3-byte (RGB) groups
      0.step(row_bytes - 1, 3) do |x|
        a = prev[x] || 0
        b = prev[x + 1] || 0
        c = prev[x + 2] || 0

        if x >= 3
          pa = curr[x - 3]
          pb = curr[x - 2]
          pc = curr[x - 1]
        else
          pa = 0
          pb = 0
          pc = 0
        end

        # Paeth predictor
        p = pa + pb - pc
        pa_abs = (p - pa).abs
        pb_abs = (p - pb).abs
        pc_abs = (p - pc).abs

        if pa_abs <= pb_abs && pa_abs <= pc_abs
          predictor = pa
        elsif pb_abs <= pc_abs
          predictor = pb
        else
          predictor = pc
        end

        curr[x] = (curr[x] - predictor).clamp(0, 255)
        curr[x + 1] = (curr[x + 1] - predictor).clamp(0, 255)
        curr[x + 2] = (curr[x + 2] - predictor).clamp(0, 255)
      end

      curr.pack("C*")
    end

    def write_chunk(type, data)
      length = [data.bytesize].pack("N")
      crc = [Zlib.crc32(type + data)].pack("N")
      length + type.b + data + crc
    end
  end
end
