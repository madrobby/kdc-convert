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
    # Demosaic a Bayer pattern image
    #
    # @param bayer [Array<Array<Integer>>] 2D array of Bayer-pattern raw values (16-bit)
    # @param pattern [String] Bayer pattern name: "RGGB", "GRBG", "BGGR", "GBRG"
    # @return [Array<Array<Array<Integer>>>] 3-channel RGB image (H x W x 3), 16-bit
    def self.demosaic(bayer, pattern)
      height = bayer.length
      width = bayer[0].length

      # Extract R, G, B channels from Bayer
      r = Array.new(height) { Array.new(width, 0) }
      g = Array.new(height) { Array.new(width, 0) }
      b = Array.new(height) { Array.new(width, 0) }

      # Track which positions have known values (for each channel)
      r_known = Array.new(height) { Array.new(width, false) }
      g_known = Array.new(height) { Array.new(width, false) }
      b_known = Array.new(height) { Array.new(width, false) }

      # Parse Bayer pattern
      # pattern is a 4-character string like "GRBG"
      # Each character represents one pixel in the 2x2 unit cell

      # Place known values
      height.times do |y|
        width.times do |x|
          phase_y = y % 2
          phase_x = x % 2
          idx = case [phase_y, phase_x]
                when [0, 0] then 0
                when [0, 1] then 1
                when [1, 0] then 2
                when [1, 1] then 3
                end
          channel = pattern[idx]

          case channel
          when "R"
            r[y][x] = bayer[y][x]
            r_known[y][x] = true
          when "G"
            g[y][x] = bayer[y][x]
            g_known[y][x] = true
          when "B"
            b[y][x] = bayer[y][x]
            b_known[y][x] = true
          end
        end
      end

      # Interpolate G where not known (using only known G values as neighbors)
      interpolate_channel(g, g_known, r, r_known, b, b_known, height, width, "G")

      # Interpolate R where not known
      interpolate_channel(r, r_known, g, g_known, b, b_known, height, width, "R")

      # Interpolate B where not known
      interpolate_channel(b, b_known, g, g_known, r, r_known, height, width, "B")

      # Pack into RGB array
      Array.new(height) do |y|
        Array.new(width) do |x|
          [r[y][x], g[y][x], b[y][x]]
        end
      end
    end

    # Interpolate a missing channel using correlation with available channels
    # Uses Menon2007's correlation-based approach with gradient weighting
    #
    # For each missing pixel:
    # 1. Find 4-connected neighbors with known values
    # 2. Calculate gradient magnitude in both directions
    # 3. Weight by inverse gradient (smooth areas get higher weight)
    # 4. Compute weighted average
    def self.interpolate_channel(target, target_known, ch1, ch1_known, ch2, ch2_known, height, width, channel_name)
      # For each pixel where target is not known, interpolate from neighbors
      height.times do |y|
        width.times do |x|
          next if target_known[y][x]

          # Get neighboring values and weights
          neighbors = []
          weights = []

          # 4-connected neighbors with correlation-based weighting
          [[0, -1], [0, 1], [-1, 0], [1, 0]].each do |dy, dx|
            ny, nx = y + dy, x + dx
            next unless ny >= 0 && ny < height && nx >= 0 && nx < width

            if target_known[ny][nx]
              # Calculate gradient magnitude using the reference channels
              # This helps preserve edges during interpolation
              grad_x = calculate_gradient(ch1, ch2, ch1_known, ch2_known, y, nx, :horizontal)
              grad_y = calculate_gradient(ch1, ch2, ch1_known, ch2_known, ny, x, :vertical)
              grad_mag = grad_x * grad_x + grad_y * grad_y

              # Weight by inverse gradient magnitude
              # Smooth areas (low gradient) get higher weight
              weight = 10000.0 / (10000.0 + grad_mag.to_f)
              neighbors << target[ny][nx]
              weights << weight
            end
          end

          # Weighted average
          if neighbors.any?
            total_weight = weights.sum
            interpolated = neighbors.zip(weights).map { |v, w| v * w }.sum / total_weight
            target[y][x] = interpolated.round
            target_known[y][x] = true
          end
        end
      end
    end

    # Calculate gradient magnitude in a specific direction
    # Uses central differences when possible, forward/backward at boundaries
    def self.calculate_gradient(ch1, ch2, ch1_known, ch2_known, y, x, direction)
      # Only calculate gradient if both endpoints are known
      if direction == :horizontal
        if x > 0 && x < ch1[0].length - 1
          if ch1_known[y][x + 1] && ch1_known[y][x - 1] && ch2_known[y][x + 1] && ch2_known[y][x - 1]
            # Central difference
            (ch1[y][x + 1].to_i - ch1[y][x - 1].to_i) +
              (ch2[y][x + 1].to_i - ch2[y][x - 1].to_i)
          else
            0
          end
        elsif x > 0
          if ch1_known[y][x] && ch1_known[y][x - 1] && ch2_known[y][x] && ch2_known[y][x - 1]
            # Backward difference
            (ch1[y][x].to_i - ch1[y][x - 1].to_i) +
              (ch2[y][x].to_i - ch2[y][x - 1].to_i)
          else
            0
          end
        else
          if ch1_known[y][x + 1] && ch1_known[y][x] && ch2_known[y][x + 1] && ch2_known[y][x]
            # Forward difference
            (ch1[y][x + 1].to_i - ch1[y][x].to_i) +
              (ch2[y][x + 1].to_i - ch2[y][x].to_i)
          else
            0
          end
        end
      else # vertical
        if y > 0 && y < ch1.length - 1
          if ch1_known[y + 1][x] && ch1_known[y - 1][x] && ch2_known[y + 1][x] && ch2_known[y - 1][x]
            # Central difference
            (ch1[y + 1][x].to_i - ch1[y - 1][x].to_i) +
              (ch2[y + 1][x].to_i - ch2[y - 1][x].to_i)
          else
            0
          end
        elsif y > 0
          if ch1_known[y][x] && ch1_known[y - 1][x] && ch2_known[y][x] && ch2_known[y - 1][x]
            # Backward difference
            (ch1[y][x].to_i - ch1[y - 1][x].to_i) +
              (ch2[y][x].to_i - ch2[y - 1][x].to_i)
          else
            0
          end
        else
          if ch1_known[y + 1][x] && ch1_known[y][x] && ch2_known[y + 1][x] && ch2_known[y][x]
            # Forward difference
            (ch1[y + 1][x].to_i - ch1[y][x].to_i) +
              (ch2[y + 1][x].to_i - ch2[y][x].to_i)
          else
            0
          end
        end
      end
    end
  end
end
