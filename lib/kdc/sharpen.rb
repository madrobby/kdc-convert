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

    # Kernel cache: key = sigma (radius)
    @@kernel_cache = {}

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

        # Preallocate result
        result = Array.new(height)
        y = 0
        while y < height
          row_img = image[y]
          row_blur = blurred[y]
          row_out = Array.new(width)
          x = 0
          while x < width
            orig_r = row_img[x][0]
            orig_g = row_img[x][1]
            orig_b = row_img[x][2]
            blur_r = row_blur[x][0]
            blur_g = row_blur[x][1]
            blur_b = row_blur[x][2]

            diff_r = orig_r - blur_r
            diff_g = orig_g - blur_g
            diff_b = orig_b - blur_b

            if diff_r.abs > threshold
              masked = (diff_r.abs - threshold) * (diff_r > 0 ? 1.0 : -1.0)
              val = orig_r + amount * masked
              v = val.round
              v = 0 if v < 0
              v = 65535 if v > 65535
              row_out[x] = [v, 0, 0]
            else
              row_out[x] = [orig_r, 0, 0]
            end

            if diff_g.abs > threshold
              masked = (diff_g.abs - threshold) * (diff_g > 0 ? 1.0 : -1.0)
              val = orig_g + amount * masked
              v = val.round
              v = 0 if v < 0
              v = 65535 if v > 65535
              row_out[x][1] = v
            else
              row_out[x][1] = orig_g
            end

            if diff_b.abs > threshold
              masked = (diff_b.abs - threshold) * (diff_b > 0 ? 1.0 : -1.0)
              val = orig_b + amount * masked
              v = val.round
              v = 0 if v < 0
              v = 65535 if v > 65535
              row_out[x][2] = v
            else
              row_out[x][2] = orig_b
            end

            x += 1
          end
          result[y] = row_out
          y += 1
        end
        result
      end

      # Separable Gaussian blur on a 16-bit RGB image.
      # Two 1D passes: horizontal then vertical.
      # Optimized: reuses buffers, caches kernel, uses Ruby's fast loops.
      def gaussian_blur(image, radius)
        sigma = [radius.to_f, 0.5].max
        half = (sigma * 3).ceil
        k_size = half * 2 + 1

        kernel = get_or_build_kernel(k_size, half, sigma)

        height = image.length
        width = image[0].length

        # Extract R, G, B channels as 2D float arrays (preallocated)
        r_ch = Array.new(height) { Array.new(width) }
        g_ch = Array.new(height) { Array.new(width) }
        b_ch = Array.new(height) { Array.new(width) }

        y = 0
        while y < height
          row = image[y]
          r_row = r_ch[y]
          g_row = g_ch[y]
          b_row = b_ch[y]
          x = 0
          while x < width
            r_row[x] = row[x][0].to_f
            g_row[x] = row[x][1].to_f
            b_row[x] = row[x][2].to_f
            x += 1
          end
          y += 1
        end

        # Two buffers for ping-pong between passes
        r_tmp = Array.new(height) { Array.new(width) }
        g_tmp = Array.new(height) { Array.new(width) }
        b_tmp = Array.new(height) { Array.new(width) }

        # Horizontal pass -> tmp buffers (accumulates into dst, no clearing needed if we overwrite)
        convolve_horiz(r_ch, r_tmp, kernel, width, height, k_size, half)
        convolve_horiz(g_ch, g_tmp, kernel, width, height, k_size, half)
        convolve_horiz(b_ch, b_tmp, kernel, width, height, k_size, half)

        # Vertical pass -> original buffers (reuse)
        convolve_vert(r_tmp, r_ch, kernel, width, height, k_size, half)
        convolve_vert(g_tmp, g_ch, kernel, width, height, k_size, half)
        convolve_vert(b_tmp, b_ch, kernel, width, height, k_size, half)

        # Recombine into 2D RGB
        result = Array.new(height)
        y = 0
        while y < height
          row = Array.new(width)
          r_row = r_ch[y]
          g_row = g_ch[y]
          b_row = b_ch[y]
          x = 0
          while x < width
            vr = r_row[x].round; vr = 0 if vr < 0; vr = 65535 if vr > 65535
            vg = g_row[x].round; vg = 0 if vg < 0; vg = 65535 if vg > 65535
            vb = b_row[x].round; vb = 0 if vb < 0; vb = 65535 if vb > 65535
            row[x] = [vr, vg, vb]
            x += 1
          end
          result[y] = row
          y += 1
        end
        result
      end

      private

      def get_or_build_kernel(k_size, half, sigma)
        @@kernel_cache[sigma] ||= build_kernel(k_size, half, sigma)
      end

      # Horizontal 1D convolution: matches original pattern (kernel outer loop, accumulates into dst)
      def convolve_horiz(src, dst, kernel, width, height, k_size, half)
        # Initialize dst to 0
        y = height
        while (y -= 1) >= 0
          dst_row = dst[y]
          x = width
          while (x -= 1) >= 0
            dst_row[x] = 0.0
          end
        end

        # Use original's pattern: kernel outer loop, accumulate into dst
        kernel.each_with_index do |k, ki|
          offset = ki - half
          y = height
          while (y -= 1) >= 0
            src_row = src[y]
            dst_row = dst[y]
            x = width
            while (x -= 1) >= 0
              nx = x + offset
              nx = 0 if nx < 0
              nx = width - 1 if nx >= width
              dst_row[x] += src_row[nx] * k
            end
          end
        end
      end

      # Vertical 1D convolution: matches original pattern
      def convolve_vert(src, dst, kernel, width, height, k_size, half)
        # Initialize dst to 0
        y = height
        while (y -= 1) >= 0
          dst_row = dst[y]
          x = width
          while (x -= 1) >= 0
            dst_row[x] = 0.0
          end
        end

        kernel.each_with_index do |k, ki|
          offset = ki - half
          y = height
          while (y -= 1) >= 0
            ry = y + offset
            ry = 0 if ry < 0
            ry = height - 1 if ry >= height
            src_row = src[ry]
            dst_row = dst[y]
            x = width
            while (x -= 1) >= 0
              dst_row[x] += src_row[x] * k
            end
          end
        end
      end

      def build_kernel(size, center, sigma)
        kernel = Array.new(size)
        i = 0
        while i < size
          x = i - center
          kernel[i] = Math.exp(-(x * x) / (2.0 * sigma * sigma))
          i += 1
        end
        sum = kernel.sum
        i = 0
        while i < size
          kernel[i] = kernel[i] / sum
          i += 1
        end
        kernel
      end
    end
  end
end