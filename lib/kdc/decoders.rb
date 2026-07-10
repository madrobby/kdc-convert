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

    def initialize(file_path, compressed: true, data_offset: 0, data_size: 0, remove_stuck_pixels: true)
      @file_path = file_path
      @compressed = compressed
      @data_offset = data_offset
      @data_size = data_size
      @remove_stuck_pixels = remove_stuck_pixels
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
            bayer[row][col] = row_data[src_col].ord
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

      # Remove stuck pixels from the decoded JPEG data before Bayer expansion
      rgb_image = remove_stuck_pixels(rgb_image) if @remove_stuck_pixels

      # Expand RGB to Bayer GRBG (matching LibRaw kodak_jpeg_load_raw)
      expand_to_bayer(rgb_image)
    end

    # Extract JPEG data from KDC file (after thumbnail)
    def extract_jpeg_data
      File.open(@file_path, "rb") do |io|
        io.pos = @data_offset
        io.read(@data_size)
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
      @data_offset
    end

    # Detect and replace stuck pixels in a decoded JPEG RGB image.
    #
    # A pixel is stuck in a channel if its value deviates from the local
    # neighbor mean by more than 20% of the local neighbor range. The
    # replacement value is the per-channel median of the 4-connected
    # neighbors. Adaptive: in noisy areas the range is wide so few pixels
    # are flagged; in clean areas the range is tight so outliers are caught.
    # Skips near-uniform areas where the local range is <= 15, since a
    # relative threshold on a tiny range produces false positives from
    # normal JPEG noise.
    #
    # Operates in-place on the image's pixel data.
    def remove_stuck_pixels(rgb_image)
      height = rgb_image.height
      width = rgb_image.width
      return rgb_image if height <= 2 || width <= 2

      height.times do |y|
        width.times do |x|
          neighbors = []
          [[0, -1], [0, 1], [-1, 0], [1, 0]].each do |dy, dx|
            ny, nx = y + dy, x + dx
            next unless ny >= 0 && ny < height && nx >= 0 && nx < width
            neighbors << rgb_image[nx, ny]
          end
          next if neighbors.empty?

          p = rgb_image[x, y]
          stuck = false
          r_out = g_out = b_out = nil

          3.times do |c|
            vals = neighbors.map { |n| n.send(%i[r g b][c]) }
            mean = vals.sum.to_f / vals.length
            range = vals.max - vals.min
            next unless range > 15
            stuck = true if (p.send(%i[r g b][c]) - mean).abs > 0.50 * range
          end

          next unless stuck

          new_r = median_of(neighbors.map(&:r))
          new_g = median_of(neighbors.map(&:g))
          new_b = median_of(neighbors.map(&:b))
          rgb_image[x, y] = PureJPEG::Source::Pixel.new(new_r, new_g, new_b)
        end
      end

      rgb_image
    end

    def median_of(values)
      sorted = values.sort
      n = sorted.length
      n.odd? ? sorted[n / 2] : ((sorted[n / 2 - 1] + sorted[n / 2]) / 2)
    end
  end
end
