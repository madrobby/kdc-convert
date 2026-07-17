# frozen_string_literal: true

require "pure_jpeg"

module KDC
  # DC120 raw data decoder
  # Ports the logic from LibRaw's kodak_dc120_load_raw() and kodak_jpeg_load_raw()
  #
  # DC120 stores raw data as JPEG YCbCr (compressed) or raw 8-bit (uncompressed).
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

    # Quality thresholds based on JPEG data size (StripByteCounts in IFD1)
    # Derived from fixture files: low=56560, medium=86070, high=176232
    QUALITY_THRESHOLDS = {
      low_high: 71_000,
      high_high: 131_000
    }.freeze

    def self.classify_quality(compression, data_size)
      return :raw if compression != 7

      if data_size < QUALITY_THRESHOLDS[:low_high]
        :low
      elsif data_size < QUALITY_THRESHOLDS[:high_high]
        :medium
      else
        :high
      end
    end

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
    # Reads 848 bytes per row with per-row shift, widens to 16-bit,
    # and removes stuck pixels from the Bayer array.
    def decode_uncompressed
      raw_bayer = Array.new(RAW_HEIGHT) { Array.new(RAW_WIDTH, 0) }

      File.open(@file_path, "rb") do |io|
        io.pos = find_data_offset(io)

        RAW_HEIGHT.times do |row|
          row_data = io.read(RAW_WIDTH)
          raise "Failed to read row #{row}" unless row_data && row_data.length == RAW_WIDTH

          shift = (row * MUL[row & 3] + ADD[row & 3]) % RAW_WIDTH

          RAW_WIDTH.times do |col|
            src_col = (col + shift) % RAW_WIDTH
            raw_bayer[row][col] = row_data[src_col].ord
          end
        end
      end

      # Values stay 0-255, matching LibRaw (ushort cast preserves the 8-bit value)
      bayer = raw_bayer

      # Remove stuck pixels from Bayer array if enabled
      bayer = remove_stuck_pixels_bayer(bayer) if @remove_stuck_pixels

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
      swapped = data.b
      i = 0
      len = swapped.bytesize - 1
      while i < len
        a = swapped.getbyte(i)
        swapped.setbyte(i, swapped.getbyte(i + 1))
        swapped.setbyte(i + 1, a)
        i += 2
      end
      swapped
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
      packed = rgb_image.packed_pixels
      jpg_width = rgb_image.width
      jpg_height = rgb_image.height

      bayer = Array.new(RAW_HEIGHT) { Array.new(RAW_WIDTH, 0) }

      row = 0
      while row < jpg_height
        bayer_row0 = row * 2
        bayer_row1 = row * 2 + 1
        base = row * jpg_width
        row0 = bayer[bayer_row0]
        row1 = bayer[bayer_row1]

        col = 0
        while col < jpg_width
          p0 = packed[base + col]
          g0 = (p0 >> 8) & 0xFF
          r0 = (p0 >> 16) & 0xFF
          b0 = p0 & 0xFF

          if col + 1 < jpg_width
            p1 = packed[base + col + 1]
            g1 = (p1 >> 8) & 0xFF
            r1 = (p1 >> 16) & 0xFF
            b1 = p1 & 0xFF

            row0[col] = g0 << 1
            row0[col + 1] = r0 + r1
            row1[col] = b0 + b1
            row1[col + 1] = g1 << 1
          else
            row0[col] = g0 << 1
            row1[col] = b0 << 1
          end

          col += 2
        end
        row += 1
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
    def remove_stuck_pixels(rgb_image)
      height = rgb_image.height
      width = rgb_image.width
      return rgb_image if height <= 2 || width <= 2

      pixels = rgb_image.packed_pixels
      result = pixels.dup

      nr = Array.new(4)
      ng = Array.new(4)
      nb = Array.new(4)

      y = 0
      while y < height
        x = 0
        while x < width
          idx = y * width + x

          ncount = 0

          if y > 0
            np = result[(y - 1) * width + x]
            nr[ncount] = (np >> 16) & 0xFF
            ng[ncount] = (np >> 8) & 0xFF
            nb[ncount] = np & 0xFF
            ncount += 1
          end
          if y + 1 < height
            np = result[(y + 1) * width + x]
            nr[ncount] = (np >> 16) & 0xFF
            ng[ncount] = (np >> 8) & 0xFF
            nb[ncount] = np & 0xFF
            ncount += 1
          end
          if x > 0
            np = result[y * width + (x - 1)]
            nr[ncount] = (np >> 16) & 0xFF
            ng[ncount] = (np >> 8) & 0xFF
            nb[ncount] = np & 0xFF
            ncount += 1
          end
          if x + 1 < width
            np = result[y * width + (x + 1)]
            nr[ncount] = (np >> 16) & 0xFF
            ng[ncount] = (np >> 8) & 0xFF
            nb[ncount] = np & 0xFF
            ncount += 1
          end

          if ncount > 0
            packed = pixels[idx]
            pr = (packed >> 16) & 0xFF
            pg = (packed >> 8) & 0xFF
            pb = packed & 0xFF

            stuck = false

            # R channel
            r_sum = nr[0]; r_min = nr[0]; r_max = nr[0]
            ni = 1
            while ni < ncount
              v = nr[ni]
              r_sum += v
              r_min = v if v < r_min
              r_max = v if v > r_max
              ni += 1
            end
            r_range = r_max - r_min
            if r_range > 15 && (pr * ncount - r_sum).abs * 2 > r_range * ncount
              stuck = true
            end

            unless stuck
              # G channel
              g_sum = ng[0]; g_min = ng[0]; g_max = ng[0]
              ni = 1
              while ni < ncount
                v = ng[ni]
                g_sum += v
                g_min = v if v < g_min
                g_max = v if v > g_max
                ni += 1
              end
              g_range = g_max - g_min
              if g_range > 15 && (pg * ncount - g_sum).abs * 2 > g_range * ncount
                stuck = true
              end
            end

            unless stuck
              # B channel
              b_sum = nb[0]; b_min = nb[0]; b_max = nb[0]
              ni = 1
              while ni < ncount
                v = nb[ni]
                b_sum += v
                b_min = v if v < b_min
                b_max = v if v > b_max
                ni += 1
              end
              b_range = b_max - b_min
              if b_range > 15 && (pb * ncount - b_sum).abs * 2 > b_range * ncount
                stuck = true
              end
            end

            if stuck
              sr = nr[0, ncount].sort
              sg = ng[0, ncount].sort
              sb = nb[0, ncount].sort
              mid = ncount / 2
              med_r = ncount.odd? ? sr[mid] : (sr[mid - 1] + sr[mid]) / 2
              med_g = ncount.odd? ? sg[mid] : (sg[mid - 1] + sg[mid]) / 2
              med_b = ncount.odd? ? sb[mid] : (sb[mid - 1] + sb[mid]) / 2
              result[idx] = (med_r << 16) | (med_g << 8) | med_b
            end
          end

          x += 1
        end
        y += 1
      end

      PureJPEG::Image.new(width, height, result, icc_profile: rgb_image.icc_profile)
    end

    def median_of(values)
      sorted = values.sort
      n = sorted.length
      n.odd? ? sorted[n / 2] : ((sorted[n / 2 - 1] + sorted[n / 2]) / 2)
    end

    # Detect and replace stuck pixels in a 16-bit Bayer GRBG array.
    #
    # For each pixel, collects same-color 4-connected neighbors (distance 2 in
    # the Bayer grid), computes the neighbor range, and flags the pixel as
    # stuck if its deviation from the mean exceeds 50% of the range (same
    # thresholds as the RGB path). Replacement value is the median of
    # same-color neighbors.
    #
    # The uncompressed raw data has per-row cyclic shifting applied, which
    # scrambles the Bayer pattern in coordinate space. This method unshifts
    # each row to reconstruct the clean GRBG grid, runs detection, then
    # re-applies the shift.
    def remove_stuck_pixels_bayer(bayer)
      height = bayer.length
      width = bayer[0].length
      return bayer if height <= 4 || width <= 4

      # Collect shift amounts per row
      shifts = height.times.map { |row| (row * MUL[row & 3] + ADD[row & 3]) % width }

      # Unshift rows to reconstruct clean Bayer grid
      grid = bayer.each_with_index.map { |row, row_idx| unshift_row(row, shifts[row_idx]) }

      # Run stuck pixel detection on clean GRBG grid
      result = grid.each_with_index.map do |row, y|
        row.each_with_index.map do |_, x|
          neighbors = same_color_neighbors(grid, x, y, height, width)
          process_bayer_pixel(grid, x, y, neighbors)
        end
      end

      # Re-apply shift to each row
      result.each_with_index.map { |row, row_idx| shift_row(row, shifts[row_idx]) }
    end

    # Reverse the per-row cyclic shift to restore original column ordering
    def unshift_row(row, shift)
      return row if shift == 0
      row.dup.rotate(-shift)
    end

    # Re-apply the per-row cyclic shift
    def shift_row(row, shift)
      return row if shift == 0
      row.dup.rotate(shift)
    end

    # Collect same-color 4-connected neighbors in GRBG Bayer pattern.
    # Neighbor offset is (0,±2) and (±2,0) for all color types.
    def same_color_neighbors(bayer, x, y, height, width)
      neighbors = []
      [[0, 2], [0, -2], [2, 0], [-2, 0]].each do |dy, dx|
        ny, nx = y + dy, x + dx
        next unless ny >= 0 && ny < height && nx >= 0 && nx < width
        neighbors << bayer[ny][nx]
      end
      neighbors
    end

    # Check if a pixel is stuck and return replacement value.
    # Returns the original value if not stuck.
    #
    # More conservative than the RGB path: uses 0.75 threshold and requires
    # a minimum absolute deviation of 200 (in 16-bit space, ~0.8 in 8-bit).
    # This prevents flagging valid pixels in textured areas where the Bayer
    # neighbor sampling (distance 2) sees natural variation.
    def process_bayer_pixel(grid, x, y, neighbors)
      return grid[y][x] if neighbors.empty?

      val = grid[y][x]
      all = [val] + neighbors
      mean = all.sum.to_f / all.length
      range = all.max - all.min

      return val if range <= 15
      return val if (val - mean).abs <= 0.75 * range
      return val if (val - mean).abs < 200

      median_of(neighbors)
    end
  end
end
