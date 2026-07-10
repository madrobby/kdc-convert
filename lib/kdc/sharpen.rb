# frozen_string_literal: true

module KDC
  # Unsharp mask sharpening via separable Gaussian blur.
  #
  # Algorithm:
  #   blurred   = gaussian_blur(image, radius)
  #   detail    = image - blurred
  #   mask      = max(0, |detail| - threshold) * sign(detail)
  #   output    = image + amount * mask
  #
  # The soft mask gradually increases sharpening above the threshold
  # instead of jumping to full amount, which avoids halos and banding.
  #
  # The separable Gaussian is two 1D passes (horizontal then vertical),
  # O(n * k) instead of O(n * k^2) for a full 2D convolution.
  module Sharpen
    AUTO_RADIUS    = 1.0
    AUTO_AMOUNT    = 1.0
    AUTO_THRESHOLD = 2

    class << self
      # Apply unsharp mask sharpening.
      #
      # @param image [Array<Array<Array<Integer>>>] 16-bit RGB image
      # @param radius [Float] Gaussian blur radius in pixels
      # @param amount [Float] Sharpening strength (multiplier on masked detail)
      # @param threshold [Integer] Ignore detail below this level (avoids noise)
      # @return [Array<Array<Array<Integer>>>] Sharpened 16-bit RGB image
      def unsharp_mask(image, radius: AUTO_RADIUS, amount: AUTO_AMOUNT, threshold: AUTO_THRESHOLD)
        blurred = gaussian_blur(image, radius)

        height = image.length
        width = image[0].length

        Array.new(height) do |y|
          row_img = image[y]
          row_blur = blurred[y]
          Array.new(width) do |x|
            rgb = [0, 0, 0]
            3.times do |c|
              orig = row_img[x][c]
              diff = orig - row_blur[x][c]

              if diff.abs > threshold
                # Soft mask: gradual ramp from threshold to full amount
                masked = (diff.abs - threshold) * (diff > 0 ? 1.0 : -1.0)
                val = orig + amount * masked
                rgb[c] = [[val.round, 0].max, 65535].min
              else
                rgb[c] = orig
              end
            end
            rgb
          end
        end
      end

      # Separable Gaussian blur on a 16-bit RGB image.
      # Two 1D passes: horizontal then vertical.
      # Channels are extracted to separate float arrays for cache efficiency.
      def gaussian_blur(image, radius)
        sigma = [radius.to_f, 0.5].max
        half = (sigma * 3).ceil
        k_size = half * 2 + 1

        kernel = build_kernel(k_size, half, sigma)

        height = image.length
        width = image[0].length

        # Extract R, G, B channels as float arrays
        channels = [
          extract_channel(image, 0, height, width),
          extract_channel(image, 1, height, width),
          extract_channel(image, 2, height, width)
        ]

        # Two separable passes per channel
        channels.map! { |ch| convolve_horiz(ch, kernel, width, height) }
        channels.map! { |ch| convolve_vert(ch, kernel, height, width) }

        # Recombine into RGB
        Array.new(height) do |y|
          Array.new(width) do |x|
            [
              clamp16(channels[0][y][x]),
              clamp16(channels[1][y][x]),
              clamp16(channels[2][y][x])
            ]
          end
        end
      end

      private

      def extract_channel(image, c, height, width)
        Array.new(height) do |y|
          row = image[y]
          Array.new(width) { |x| row[x][c].to_f }
        end
      end

      # Horizontal 1D convolution — accumulates kernel taps across pixels.
      def convolve_horiz(channel, kernel, width, height)
        half = kernel.length / 2
        result = Array.new(height) { Array.new(width, 0.0) }

        kernel.each_with_index do |k, ki|
          offset = ki - half
          y = height
          while (y -= 1) >= 0
            row = channel[y]
            res_row = result[y]
            x = width
            while (x -= 1) >= 0
              nx = x + offset
              nx = 0           if nx < 0
              nx = width - 1   if nx >= width
              res_row[x] += row[nx] * k
            end
          end
        end
        result
      end

      # Vertical 1D convolution — accumulates kernel taps across rows.
      def convolve_vert(channel, kernel, height, width)
        half = kernel.length / 2
        result = Array.new(height) { Array.new(width, 0.0) }

        kernel.each_with_index do |k, ki|
          offset = ki - half
          y = height
          while (y -= 1) >= 0
            ry = y + offset
            ry = 0           if ry < 0
            ry = height - 1  if ry >= height
            row = channel[ry]
            res_row = result[y]
            x = width
            while (x -= 1) >= 0
              res_row[x] += row[x] * k
            end
          end
        end
        result
      end

      def clamp16(val)
        v = val.round
        v = 0     if v < 0
        v = 65535 if v > 65535
        v
      end

      def build_kernel(size, center, sigma)
        kernel = Array.new(size)
        size.times do |i|
          x = i - center
          kernel[i] = Math.exp(-(x * x) / (2.0 * sigma * sigma))
        end
        sum = kernel.sum
        kernel.map! { |v| v / sum }
        kernel
      end
    end
  end
end
