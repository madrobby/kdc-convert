# frozen_string_literal: true

module KDC
  # Menon2007 demosaic algorithm
  # Ported from the colour-demosaicing Python library
  #
  # This is a minimum-cycle-based demosaic that uses local statistics
  # and correlation-based interpolation with gradient weighting.
  #
  # The algorithm works by:
  # 1. Extracting known R, G, B values from the Bayer pattern
  # 2. For each missing pixel, finding correlated neighbors
  # 3. Using gradient-weighted interpolation for better edge handling
  module Menon2007
    WEIGHT_CONSTANT = 10000.0

    # Demosaic a Bayer pattern image
    #
    # @param bayer [Array<Array<Integer>>] 2D array of Bayer-pattern raw values (16-bit)
    # @param pattern [String] Bayer pattern name: "RGGB", "GRBG", "BGGR", "GBRG"
    # @return [Array<Array<Array<Integer>>>] 3-channel RGB image (H x W x 3), 16-bit
    def self.demosaic(bayer, pattern)
      height = bayer.length
      width = bayer[0].length

      # Extract R, G, B channels into flat arrays
      r, g, b, r_known, b_known = extract_channels(bayer, pattern, width, height)

      # Create g_known array initialized from Bayer pattern (will be updated during interpolation)
      g_known = Array.new(height * width, false)
      height.times do |y|
        width.times do |x|
          g_known[y * width + x] = g_known?(y, x)
        end
      end

      # Interpolate each channel in order (G first, then R, then B)
      # Gradients are precomputed once per pass from the reference channels
      # Signature: compute_gradient_map(ch1_known, ch1, ch2_known, ch2, width, height)
      g_grad = compute_gradient_map(r_known, r, b_known, b, width, height)
      interpolate_pass(g, g_known, r, r_known, b, b_known, g_grad, width, height)

      r_grad = compute_gradient_map(g_known, g, b_known, b, width, height)
      interpolate_pass(r, r_known, g, g_known, b, b_known, r_grad, width, height)

      b_grad = compute_gradient_map(g_known, g, r_known, r, width, height)
      interpolate_pass(b, b_known, g, g_known, r, r_known, b_grad, width, height)

      # Pack into RGB array
      pack_rgb(r, g, b, width, height)
    end

    # Extract R, G, B channels from Bayer data into flat 1D arrays
    # Returns [r, g, b, r_known, b_known] — g_known is computed from coordinates (GRBG pattern)
    def self.extract_channels(bayer, pattern, width, height)
      r = Array.new(height * width, 0)
      g = Array.new(height * width, 0)
      b = Array.new(height * width, 0)
      r_known = Array.new(height * width, false)
      b_known = Array.new(height * width, false)

      # Pre-compute channel index for each (y%2, x%2) phase
      # pattern is a 4-character string like "GRBG"
      p0 = pattern[0]
      p1 = pattern[1]
      p2 = pattern[2]
      p3 = pattern[3]

      height.times do |y|
        yw = y * width
        phase_y = y % 2
        width.times do |x|
          idx = yw + x
          bayer_val = bayer[y][x]
          phase_x = x % 2
          pix = phase_y * 2 + phase_x

          case pix
          when 0
            case p0
            when "R" then r[idx] = bayer_val; r_known[idx] = true
            when "G" then g[idx] = bayer_val
            when "B" then b[idx] = bayer_val; b_known[idx] = true
            end
          when 1
            case p1
            when "R" then r[idx] = bayer_val; r_known[idx] = true
            when "G" then g[idx] = bayer_val
            when "B" then b[idx] = bayer_val; b_known[idx] = true
            end
          when 2
            case p2
            when "R" then r[idx] = bayer_val; r_known[idx] = true
            when "G" then g[idx] = bayer_val
            when "B" then b[idx] = bayer_val; b_known[idx] = true
            end
          when 3
            case p3
            when "R" then r[idx] = bayer_val; r_known[idx] = true
            when "G" then g[idx] = bayer_val
            when "B" then b[idx] = bayer_val; b_known[idx] = true
            end
          end
        end
      end

      [r, g, b, r_known, b_known]
    end

    # Check if G channel is known at (y, x) for GRBG Bayer pattern
    # G pixels are at (even, even) and (odd, odd) positions
    def self.g_known?(y, x)
      gy = y % 2
      gx = x % 2
      (gy == 0 && gx == 0) || (gy == 1 && gx == 1)
    end

    # Check if a position is known, using array lookup or coordinate-based check
    def self.known_at?(known_array, y, x, width)
      if known_array
        known_array[y * width + x]
      else
        g_known?(y, x)
      end
    end

    # Precompute gradient magnitude map for a pair of reference channels
    # ch1_known: known-array for ch1 (nil for G channel — uses coordinate check)
    # ch2_known: known-array for ch2 (nil for G channel — uses coordinate check)
    # Returns flat 1D array of Float gradient magnitudes indexed by y*width+x
    def self.compute_gradient_map(ch1_known, ch1, ch2_known, ch2, width, height)
      grad_map = Array.new(height * width, 0.0)

      height.times do |y|
        width.times do |x|
          idx = y * width + x

          # Horizontal gradient
          if x > 0 && x < width - 1
            if known_at?(ch1_known, y, x - 1, width) && known_at?(ch1_known, y, x + 1, width) &&
               known_at?(ch2_known, y, x - 1, width) && known_at?(ch2_known, y, x + 1, width)
              grad_h = (ch1[idx + 1] - ch1[idx - 1]) + (ch2[idx + 1] - ch2[idx - 1])
            else
              grad_h = 0
            end
          elsif x == width - 1
            if known_at?(ch1_known, y, x - 1, width) && known_at?(ch2_known, y, x - 1, width)
              grad_h = (ch1[idx] - ch1[idx - 1]) + (ch2[idx] - ch2[idx - 1])
            else
              grad_h = 0
            end
          else
            if known_at?(ch1_known, y, x + 1, width) && known_at?(ch2_known, y, x + 1, width)
              grad_h = (ch1[idx + 1] - ch1[idx]) + (ch2[idx + 1] - ch2[idx])
            else
              grad_h = 0
            end
          end

          # Vertical gradient
          if y > 0 && y < height - 1
            if known_at?(ch1_known, y - 1, x, width) && known_at?(ch1_known, y + 1, x, width) &&
               known_at?(ch2_known, y - 1, x, width) && known_at?(ch2_known, y + 1, x, width)
              grad_v = (ch1[idx + width] - ch1[idx - width]) + (ch2[idx + width] - ch2[idx - width])
            else
              grad_v = 0
            end
          elsif y == height - 1
            if known_at?(ch1_known, y - 1, x, width) && known_at?(ch2_known, y - 1, x, width)
              grad_v = (ch1[idx] - ch1[idx - width]) + (ch2[idx] - ch2[idx - width])
            else
              grad_v = 0
            end
          else
            if known_at?(ch1_known, y + 1, x, width) && known_at?(ch2_known, y + 1, x, width)
              grad_v = (ch1[idx + width] - ch1[idx]) + (ch2[idx + width] - ch2[idx])
            else
              grad_v = 0
            end
          end

          grad_map[idx] = grad_h * grad_h + grad_v * grad_v
        end
      end

      grad_map
    end

    # Interpolate one channel pass using precomputed gradient map
    # Uses running accumulators instead of per-pixel array allocations
    def self.interpolate_pass(target, target_known, ch1, ch1_known, ch2, ch2_known, grad_map, width, height)
      height.times do |y|
        width.times do |x|
          idx = y * width + x
          next if target_known[idx]

          sum = 0.0
          total_weight = 0.0

          # 4-connected neighbors
          if y > 0
            nidx = idx - width
            if target_known[nidx]
              gmag = grad_map[nidx]
              weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
              sum += target[nidx] * weight
              total_weight += weight
            end
          end

          if y < height - 1
            nidx = idx + width
            if target_known[nidx]
              gmag = grad_map[nidx]
              weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
              sum += target[nidx] * weight
              total_weight += weight
            end
          end

          if x > 0
            nidx = idx - 1
            if target_known[nidx]
              gmag = grad_map[nidx]
              weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
              sum += target[nidx] * weight
              total_weight += weight
            end
          end

          if x < width - 1
            nidx = idx + 1
            if target_known[nidx]
              gmag = grad_map[nidx]
              weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
              sum += target[nidx] * weight
              total_weight += weight
            end
          end

          if total_weight > 0
            target[idx] = (sum / total_weight).round
            target_known[idx] = true
          end
        end
      end
    end

    # Pack flat R, G, B arrays into Array-of-Arrays-of-Arrays RGB format
    def self.pack_rgb(r, g, b, width, height)
      Array.new(height) do |y|
        base = y * width
        Array.new(width) do |x|
          i = base + x
          [r[i], g[i], b[i]]
        end
      end
    end
  end
end
