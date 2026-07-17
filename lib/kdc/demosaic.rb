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
    INV_WEIGHT_CONSTANT = 1.0 / 10000.0

    # Demosaic a Bayer pattern image
    #
    # @param bayer [Array<Array<Integer>>] 2D array of Bayer-pattern raw values (16-bit)
    # @param pattern [String] Bayer pattern name: "RGGB", "GRBG", "BGGR", "GBRG"
    # @return [Array<Array<Array<Integer>>>] 3-channel RGB image (H x W x 3), 16-bit
    def self.demosaic(bayer, pattern)
      height = bayer.length
      width = bayer[0].length
      total_pixels = height * width
      w = width
      h = height

      # Flatten bayer to 1D array for faster access
      bayer_flat = Array.new(total_pixels)
      i = 0
      y = 0
      while y < h
        row = bayer[y]
        x = 0
        while x < w
          bayer_flat[i] = row[x]
          i += 1
          x += 1
        end
        y += 1
      end

      # Extract channels into flat arrays
      r, g, b, r_known, b_known = extract_channels_flat(bayer_flat, pattern, w, h, total_pixels)

      # g_known: G at (even,even) and (odd,odd) for GRBG pattern
      g_known = Array.new(total_pixels, false)
      i = 0
      while i < total_pixels
        # For GRBG: G at positions where (y%2) == (x%2)
        # i / w = y, i % w = x
        g_known[i] = ((i / w) & 1) == (i & 1)
        i += 1
      end

      # Interpolation passes: G first (using R,B as reference), then R, then B
      g_grad = compute_gradient_map(r_known, r, b_known, b, w, h, total_pixels)
      interpolate_pass(g, g_known, g_grad, w, h, total_pixels)

      r_grad = compute_gradient_map(g_known, g, b_known, b, w, h, total_pixels)
      interpolate_pass(r, r_known, r_grad, w, h, total_pixels)

      b_grad = compute_gradient_map(g_known, g, r_known, r, w, h, total_pixels)
      interpolate_pass(b, b_known, b_grad, w, h, total_pixels)

      pack_rgb(r, g, b, w, h)
    end

    # Extract R, G, B channels from flat Bayer data into flat 1D arrays
    # Returns [r, g, b, r_known, b_known]
    def self.extract_channels_flat(bayer_flat, pattern, w, h, total)
      r = Array.new(total, 0)
      g = Array.new(total, 0)
      b = Array.new(total, 0)
      r_known = Array.new(total, false)
      b_known = Array.new(total, false)

      p0 = pattern[0]
      p1 = pattern[1]
      p2 = pattern[2]
      p3 = pattern[3]

      i = 0
      y = 0
      while y < h
        phase_y = y & 1
        x = 0
        while x < w
          bayer_val = bayer_flat[i]
          phase_x = x & 1
          pix = (phase_y << 1) | phase_x

          case pix
          when 0
            case p0
            when "R"; r[i] = bayer_val; r_known[i] = true
            when "G"; g[i] = bayer_val
            when "B"; b[i] = bayer_val; b_known[i] = true
            end
          when 1
            case p1
            when "R"; r[i] = bayer_val; r_known[i] = true
            when "G"; g[i] = bayer_val
            when "B"; b[i] = bayer_val; b_known[i] = true
            end
          when 2
            case p2
            when "R"; r[i] = bayer_val; r_known[i] = true
            when "G"; g[i] = bayer_val
            when "B"; b[i] = bayer_val; b_known[i] = true
            end
          when 3
            case p3
            when "R"; r[i] = bayer_val; r_known[i] = true
            when "G"; g[i] = bayer_val
            when "B"; b[i] = bayer_val; b_known[i] = true
            end
          end

          i += 1
          x += 1
        end
        y += 1
      end

      [r, g, b, r_known, b_known]
    end

    # Precompute gradient magnitude map for a pair of reference channels
    # Returns flat 1D array of Float gradient magnitudes indexed by y*width+x
    def self.compute_gradient_map(ch1_known, ch1, ch2_known, ch2, w, h, total)
      grad_map = Array.new(total, 0.0)

      i = 0
      y = 0
      while y < h
        x = 0
        while x < w
          # Horizontal gradient
          if x > 0 && x < w - 1
            if ch1_known[i - 1] && ch1_known[i + 1] && ch2_known[i - 1] && ch2_known[i + 1]
              grad_h = (ch1[i + 1] - ch1[i - 1]) + (ch2[i + 1] - ch2[i - 1])
            else
              grad_h = 0
            end
          elsif x == w - 1
            if ch1_known[i - 1] && ch2_known[i - 1]
              grad_h = (ch1[i] - ch1[i - 1]) + (ch2[i] - ch2[i - 1])
            else
              grad_h = 0
            end
          else # x == 0
            if ch1_known[i + 1] && ch2_known[i + 1]
              grad_h = (ch1[i + 1] - ch1[i]) + (ch2[i + 1] - ch2[i])
            else
              grad_h = 0
            end
          end

          # Vertical gradient
          if y > 0 && y < h - 1
            idx_up = i - w
            idx_down = i + w
            if ch1_known[idx_up] && ch1_known[idx_down] && ch2_known[idx_up] && ch2_known[idx_down]
              grad_v = (ch1[idx_down] - ch1[idx_up]) + (ch2[idx_down] - ch2[idx_up])
            else
              grad_v = 0
            end
          elsif y == h - 1
            idx_up = i - w
            if ch1_known[idx_up] && ch2_known[idx_up]
              grad_v = (ch1[i] - ch1[idx_up]) + (ch2[i] - ch2[idx_up])
            else
              grad_v = 0
            end
          else # y == 0
            idx_down = i + w
            if ch1_known[idx_down] && ch2_known[idx_down]
              grad_v = (ch1[idx_down] - ch1[i]) + (ch2[idx_down] - ch2[i])
            else
              grad_v = 0
            end
          end

          grad_map[i] = grad_h * grad_h + grad_v * grad_v

          i += 1
          x += 1
        end
        y += 1
      end

      grad_map
    end

    # Interpolate one channel pass using precomputed gradient map
    def self.interpolate_pass(target, target_known, grad_map, w, h, total)
      i = 0
      y = 0
      while y < h
        x = 0
        while x < w
          unless target_known[i]
            sum = 0.0
            total_weight = 0.0

            # Up neighbor
            if y > 0
              nidx = i - w
              if target_known[nidx]
                gmag = grad_map[nidx]
                weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
                sum += target[nidx] * weight
                total_weight += weight
              end
            end

            # Down neighbor
            if y < h - 1
              nidx = i + w
              if target_known[nidx]
                gmag = grad_map[nidx]
                weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
                sum += target[nidx] * weight
                total_weight += weight
              end
            end

            # Left neighbor
            if x > 0
              nidx = i - 1
              if target_known[nidx]
                gmag = grad_map[nidx]
                weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
                sum += target[nidx] * weight
                total_weight += weight
              end
            end

            # Right neighbor
            if x < w - 1
              nidx = i + 1
              if target_known[nidx]
                gmag = grad_map[nidx]
                weight = WEIGHT_CONSTANT / (WEIGHT_CONSTANT + gmag)
                sum += target[nidx] * weight
                total_weight += weight
              end
            end

            if total_weight > 0
              target[i] = (sum / total_weight).round
              target_known[i] = true
            end
          end

          i += 1
          x += 1
        end
        y += 1
      end
    end

    # Pack flat R, G, B arrays into Array-of-Arrays-of-Arrays RGB format
    def self.pack_rgb(r, g, b, w, h)
      result = Array.new(h)
      y = 0
      while y < h
        row = Array.new(w)
        base = y * w
        x = 0
        while x < w
          i = base + x
          row[x] = [r[i], g[i], b[i]]
          x += 1
        end
        result[y] = row
        y += 1
      end
      result
    end
  end
end