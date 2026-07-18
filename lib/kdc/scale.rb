# frozen_string_literal: true

module KDC
  # Bit depth and tonal scaling operations
  module Scale
    # Scale 16-bit image to 8-bit via bit shift (for PNG output)
    def self.to_8bit(image)
      return nil unless image

      height = image.length
      width = image[0].length

      flat = Array.new(height * width * 3)
      idx = 0
      y = 0
      while y < height
        row = image[y]
        x = 0
        while x < width
          pixel = row[x]
          flat[idx] = (pixel[0] >> 8)
          flat[idx + 1] = (pixel[1] >> 8)
          flat[idx + 2] = (pixel[2] >> 8)
          idx += 3
          x += 1
        end
        y += 1
      end

      result = Array.new(height)
      y = 0
      idx = 0
      while y < height
        row = Array.new(width)
        x = 0
        while x < width
          row[x] = [flat[idx], flat[idx + 1], flat[idx + 2]]
          idx += 3
          x += 1
        end
        result[y] = row
        y += 1
      end
      result
    end

    # Scale to fill 16-bit range (for DNG output)
    def self.to_16bit(image, white_level)
      scale_factor = 65535.0 / white_level
      image.map do |row|
        row.map do |r, g, b|
          [
            [(r * scale_factor).round, 65535].min,
            [(g * scale_factor).round, 65535].min,
            [(b * scale_factor).round, 65535].min
          ]
        end
      end
    end

    # Scale to fill 16-bit range (in-place, efficient for pipeline)
    def self.scale_16bit_in_place!(image, white_level)
      return unless image

      scale_factor = 65535.0 / white_level
      height = image.length
      width = image[0].length
      y = 0
      while y < height
        row = image[y]
        x = 0
        while x < width
          pixel = row[x]
          r = (pixel[0] * scale_factor).round
          g = (pixel[1] * scale_factor).round
          b = (pixel[2] * scale_factor).round
          r = 65535 if r > 65535
          g = 65535 if g > 65535
          b = 65535 if b > 65535
          pixel[0] = r
          pixel[1] = g
          pixel[2] = b
          x += 1
        end
        y += 1
      end
    end
  end
end
