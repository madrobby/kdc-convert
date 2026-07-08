# frozen_string_literal: true

require "pure_jpeg"

module KDC
  # DC120 raw data decoder
  # Ports the logic from LibRaw's kodak_dc120_load_raw() and kodak_jpeg_load_raw()
  #
  # DC120 stores raw data as JPEG YCbCr (compressed) or raw 8-bit (uncompressed).
  # All sample files are compressed.
  #
  # The JPEG decoder outputs RGB, then we expand to Bayer GRBG pattern:
  #   RAW(row+0, col+0) = G (from JPEG green channel)
  #   RAW(row+0, col+1) = R (from JPEG red channel, summed across pair)
  #   RAW(row+1, col+0) = B (from JPEG blue channel, summed across pair)
  #   RAW(row+1, col+1) = G (from JPEG green channel)
  class DC120Decoder
    RAW_WIDTH  = 848
    RAW_HEIGHT = 976

    # Shift tables from LibRaw kodak_decoders.cpp
    MUL = [162, 192, 187, 92].freeze
    ADD = [0, 636, 424, 212].freeze

    def initialize(file_path, compressed: true)
      @file_path = file_path
      @compressed = compressed
    end

    # Decode raw Bayer data
    # Returns a 2D array (RAW_HEIGHT x RAW_WIDTH) of 16-bit values
    def decode
      if @compressed
        decode_compressed
      else
        decode_uncompressed
      end
    end

    private

    # Uncompressed decoder (kodak_dc120_load_raw)
    # Reads 848 bytes per row with per-row shift
    def decode_uncompressed
      bayer = Array.new(RAW_HEIGHT) { Array.new(RAW_WIDTH, 0) }

      File.open(@file_path, "rb") do |io|
        io.pos = find_data_offset(io)

        RAW_HEIGHT.times do |row|
          row_data = io.read(RAW_WIDTH)
          raise "Failed to read row #{row}" unless row_data && row_data.length == RAW_WIDTH

          shift = (row * MUL[row & 3] + ADD[row & 3]) % RAW_WIDTH

          RAW_WIDTH.times do |col|
            src_col = (col + shift) % RAW_WIDTH
            bayer[row][col] = row_data[src_col].ord << 8
          end
        end
      end

      bayer
    end

    # Compressed decoder (kodak_jpeg_load_raw)
    # Extracts JPEG data, byte-swaps, decodes to RGB using pure_jpeg,
    # then expands to Bayer GRBG
    def decode_compressed
      jpg_data = extract_jpeg_data
      swapped = byte_swap(jpg_data)

      # Decode JPEG to RGB using pure_jpeg
      rgb_image = PureJPEG.read(swapped)

      # Expand RGB to Bayer GRBG (matching LibRaw kodak_jpeg_load_raw)
      expand_to_bayer(rgb_image)
    end

    # Extract JPEG data from KDC file (after thumbnail)
    def extract_jpeg_data
      File.open(@file_path, "rb") do |io|
        io.pos = 8
        num_entries = io.read(2).unpack1("n")

        strip_offset = nil
        strip_bytes = nil

        num_entries.times do |i|
          entry_start = 8 + 2 + i * 12
          io.pos = entry_start
          tag = io.read(2).unpack1("n")
          type = io.read(2).unpack1("n")
          count = io.read(4).unpack1("N")
          value = io.read(4).unpack1("N")

          if tag == 0x0111
            strip_offset = value
          elsif tag == 0x0117
            strip_bytes = value
          end
        end

        io.pos = strip_offset + strip_bytes
        io.read
      end
    end

    # Byte-swap data (16-bit words)
    def byte_swap(data)
      data.bytes.each_slice(2).map { |a, b| [b, a] }.flatten.pack("C*")
    end

    # Expand RGB to Bayer GRBG pattern
    # Matching LibRaw kodak_jpeg_load_raw logic:
    #   pixel[col][0] = R, pixel[col][1] = G, pixel[col][2] = B
    #   For each pair of columns (col, col+1):
    #     RAW(row*2+0, col+0) = G[col] << 1
    #     RAW(row*2+0, col+1) = R[col] + R[col+1]
    #     RAW(row*2+1, col+0) = B[col] + B[col+1]
    #     RAW(row*2+1, col+1) = G[col+1] << 1
    def expand_to_bayer(rgb_image)
      bayer = Array.new(RAW_HEIGHT) { Array.new(RAW_WIDTH, 0) }

      # Process rows: each JPEG row maps to 2 Bayer rows
      rgb_image.height.times do |row|
        bayer_row0 = row * 2
        bayer_row1 = row * 2 + 1

        # Process columns in pairs (matching LibRaw: col += 2)
        col = 0
        while col < rgb_image.width
          pixel0 = rgb_image[col, row]
          r_val0, g_val0, b_val0 = pixel0.r, pixel0.g, pixel0.b

          if col + 1 < rgb_image.width
            pixel1 = rgb_image[col + 1, row]
            r_val1, g_val1, b_val1 = pixel1.r, pixel1.g, pixel1.b

            # GRBG pattern (matching LibRaw)
            bayer[bayer_row0][col] = g_val0 << 1                    # G
            bayer[bayer_row0][col + 1] = r_val0 + r_val1           # R
            bayer[bayer_row1][col] = b_val0 + b_val1               # B
            bayer[bayer_row1][col + 1] = g_val1 << 1               # G
          else
            # Odd column at edge - just use single pixel values
            bayer[bayer_row0][col] = g_val0 << 1
            bayer[bayer_row1][col] = b_val0 << 1
          end

          col += 2
        end
      end

      bayer
    end

    # Find data offset (after thumbnail)
    def find_data_offset(io)
      io.pos = 8
      num_entries = io.read(2).unpack1("n")

      strip_offset = nil
      strip_bytes = nil

      num_entries.times do |i|
        entry_start = 8 + 2 + i * 12
        io.pos = entry_start
        tag = io.read(2).unpack1("n")
        type = io.read(2).unpack1("n")
        count = io.read(4).unpack1("N")
        value = io.read(4).unpack1("N")

        if tag == 0x0111
          strip_offset = value
        elsif tag == 0x0117
          strip_bytes = value
        end
      end

      strip_offset + strip_bytes
    end
  end
end
