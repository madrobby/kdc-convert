# frozen_string_literal: true

module KDC
  # Stuck pixel detection and removal.
  #
  # Provides two detection modes:
  # - RGB: per-channel 4-connected neighbor analysis on packed ARGB pixels
  # - Bayer: same-color 4-connected neighbor analysis (distance 2) on Bayer grid
  #
  # Shared thresholds:
  #   MIN_RANGE = 15       — skip near-uniform areas to avoid false positives
  #   REL_THRESHOLD = 0.5  — per-channel RGB deviation threshold
  #   BAYER_THRESHOLD = 0.75 — same-color Bayer deviation threshold
  #   BAYER_ABS_MIN = 200  — minimum absolute deviation in Bayer mode
  module StuckPixel
    MIN_RANGE       = 15
    REL_THRESHOLD   = 0.5
    BAYER_THRESHOLD = 0.75
    BAYER_ABS_MIN   = 200

    class << self
      # Detect and replace stuck pixels in a decoded JPEG RGB image.
      #
      # A pixel is stuck in a channel if its value deviates from the local
      # neighbor mean by more than REL_THRESHOLD of the local neighbor range.
      # The replacement value is the per-channel median of the 4-connected
      # neighbors.
      #
      # @param pixels [Array<Integer>] flat array of packed ARGB (0xAARRGGBB)
      # @param width [Integer]
      # @param height [Integer]
      # @return [Array<Integer>] corrected pixels
      def fix_rgb(pixels, width, height)
        return pixels if height <= 2 || width <= 2

        result = pixels.dup
        nr = Array.new(4)
        ng = Array.new(4)
        nb = Array.new(4)

        y = 0
        while y < height
          x = 0
          while x < width
            idx = y * width + x
            ncount = collect_rgb_neighbors(result, x, y, width, height, nr, ng, nb)

            if ncount > 0
              packed = pixels[idx]
              pr = (packed >> 16) & 0xFF
              pg = (packed >> 8) & 0xFF
              pb = packed & 0xFF

              stuck = channel_stuck?(nr, ncount, pr) ||
                      channel_stuck?(ng, ncount, pg) ||
                      channel_stuck?(nb, ncount, pb)

              if stuck
                med_r = median_of(nr, ncount)
                med_g = median_of(ng, ncount)
                med_b = median_of(nb, ncount)
                result[idx] = (med_r << 16) | (med_g << 8) | med_b
              end
            end

            x += 1
          end
          y += 1
        end

        result
      end

      # Detect and replace stuck pixels in a 2D Bayer GRBG array.
      #
      # For each pixel, collects same-color 4-connected neighbors (distance 2
      # in the Bayer grid), computes the neighbor range, and flags the pixel as
      # stuck if its deviation from the mean exceeds BAYER_THRESHOLD of the
      # range AND the absolute deviation exceeds BAYER_ABS_MIN.
      #
      # @param bayer [Array<Array<Integer>>] 2D array of Bayer-pattern raw values
      # @return [Array<Array<Integer>>] corrected Bayer array
      def fix_bayer_2d(bayer)
        height = bayer.length
        width = bayer[0].length
        return bayer if height <= 4 || width <= 4

        result = bayer.map(&:dup)
        y = 0
        while y < height
          x = 0
          while x < width
            neighbors = same_color_neighbors(bayer, x, y, height, width)
            val = bayer[y][x]
            replacement = check_and_replace(val, neighbors)
            result[y][x] = replacement if replacement != val
            x += 1
          end
          y += 1
        end
        result
      end

      # Detect and replace stuck pixels in a flat Bayer array (row-major).
      #
      # @param raw [Array<Integer>] flat 1D array (height * width)
      # @param width [Integer]
      # @param height [Integer]
      # @return [Array<Integer>] corrected flat array
      def fix_bayer_flat(raw, width, height)
        return raw if height <= 4 || width <= 4

        result = raw.dup
        y = 0
        while y < height
          x = 0
          while x < width
            idx = y * width + x
            neighbors = []
            [[0, 2], [0, -2], [2, 0], [-2, 0]].each do |dy, dx|
              ny = y + dy
              nx = x + dx
              next unless ny >= 0 && ny < height && nx >= 0 && nx < width
              neighbors << raw[ny * width + nx]
            end
            val = raw[idx]
            replacement = check_and_replace(val, neighbors)
            result[idx] = replacement if replacement != val
            x += 1
          end
          y += 1
        end
        result
      end

      private

      # Check if a single channel value is stuck based on its neighbors.
      def channel_stuck?(neighbor_vals, ncount, pixel_val)
        sum = neighbor_vals[0]
        min = neighbor_vals[0]
        max = neighbor_vals[0]
        i = 1
        while i < ncount
          v = neighbor_vals[i]
          sum += v
          min = v if v < min
          max = v if v > max
          i += 1
        end
        range = max - min
        range > MIN_RANGE && (pixel_val * ncount - sum).abs * 2 > range * ncount
      end

      # Collect 4-connected RGB neighbors and unpack their channels.
      def collect_rgb_neighbors(pixels, x, y, width, height, nr, ng, nb)
        ncount = 0
        if y > 0
          unpack_neighbor(pixels[(y - 1) * width + x], nr, ng, nb, ncount)
          ncount += 1
        end
        if y + 1 < height
          unpack_neighbor(pixels[(y + 1) * width + x], nr, ng, nb, ncount)
          ncount += 1
        end
        if x > 0
          unpack_neighbor(pixels[y * width + (x - 1)], nr, ng, nb, ncount)
          ncount += 1
        end
        if x + 1 < width
          unpack_neighbor(pixels[y * width + (x + 1)], nr, ng, nb, ncount)
          ncount += 1
        end
        ncount
      end

      def unpack_neighbor(packed, nr, ng, nb, idx)
        nr[idx] = (packed >> 16) & 0xFF
        ng[idx] = (packed >> 8) & 0xFF
        nb[idx] = packed & 0xFF
      end

      # Compute median of the first n values in an array.
      def median_of(values, n)
        sorted = values[0, n].sort
        n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
      end

      # Collect same-color 4-connected neighbors in GRBG Bayer pattern.
      def same_color_neighbors(bayer, x, y, height, width)
        neighbors = []
        [[0, 2], [0, -2], [2, 0], [-2, 0]].each do |dy, dx|
          ny, nx = y + dy, x + dx
          next unless ny >= 0 && ny < height && nx >= 0 && nx < width
          neighbors << bayer[ny][nx]
        end
        neighbors
      end

      # Check if a Bayer pixel is stuck and return replacement value.
      def check_and_replace(val, neighbors)
        return val if neighbors.empty?

        all = [val] + neighbors
        mean = all.sum.to_f / all.length
        range = all.max - all.min

        return val if range <= MIN_RANGE
        return val if (val - mean).abs <= BAYER_THRESHOLD * range
        return val if (val - mean).abs < BAYER_ABS_MIN

        sorted = neighbors.sort
        n = sorted.length
        n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
      end
    end
  end
end
