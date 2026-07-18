# frozen_string_literal: true

module KDC
  # Bilinear resize for RGB images
  module Resize
    # Bilinear resize (pure Ruby implementation)
    def self.bilinear(image, target_width, target_height)
      src_height = image.length
      src_width = image[0].length

      x_ratio = src_width.to_f / target_width
      y_ratio = src_height.to_f / target_height

      # Pre-compute x weights (reused across all rows)
      x_weights = Array.new(target_width)
      tx = 0
      while tx < target_width
        src_x = tx * x_ratio
        x0 = src_x.floor
        x1 = x0 + 1
        x1 = src_width - 1 if x1 >= src_width
        fx = src_x - x0
        x_weights[tx] = [x0, x1, fx, 1.0 - fx]
        tx += 1
      end

      # Pre-compute y weights (reused across all columns)
      y_weights = Array.new(target_height)
      ty = 0
      while ty < target_height
        src_y = ty * y_ratio
        y0 = src_y.floor
        y1 = y0 + 1
        y1 = src_height - 1 if y1 >= src_height
        fy = src_y - y0
        y_weights[ty] = [y0, y1, fy, 1.0 - fy]
        ty += 1
      end

      # Preallocate flat result array
      result = Array.new(target_height * target_width * 3)
      ty = 0
      idx = 0
      while ty < target_height
        y0, y1, fy, fy_inv = y_weights[ty]
        tx = 0
        while tx < target_width
          x0, x1, fx, fx_inv = x_weights[tx]

          # Interpolate each channel (unrolled)
          r0 = image[y0][x0][0] * fx_inv + image[y0][x1][0] * fx
          r1 = image[y1][x0][0] * fx_inv + image[y1][x1][0] * fx
          r  = (r0 * fy_inv + r1 * fy).round
          r  = 65535 if r > 65535

          g0 = image[y0][x0][1] * fx_inv + image[y0][x1][1] * fx
          g1 = image[y1][x0][1] * fx_inv + image[y1][x1][1] * fx
          g  = (g0 * fy_inv + g1 * fy).round
          g  = 65535 if g > 65535

          b0 = image[y0][x0][2] * fx_inv + image[y0][x1][2] * fx
          b1 = image[y1][x0][2] * fx_inv + image[y1][x1][2] * fx
          b  = (b0 * fy_inv + b1 * fy).round
          b  = 65535 if b > 65535

          result[idx] = r
          result[idx + 1] = g
          result[idx + 2] = b
          idx += 3

          tx += 1
        end
        ty += 1
      end

      # Reshape to 2D for compatibility
      output = Array.new(target_height)
      ty = 0
      idx = 0
      while ty < target_height
        row = Array.new(target_width)
        tx = 0
        while tx < target_width
          row[tx] = [result[idx], result[idx + 1], result[idx + 2]]
          idx += 3
          tx += 1
        end
        output[ty] = row
        ty += 1
      end
      output
    end
  end
end
