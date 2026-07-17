# frozen_string_literal: true

require "json"

module KDC
  # Color correction: per-channel linear transform + percentile-based stretch.
  #
  # Matches the Python version's apply_color_correction():
  #   x = input_16bit / 256.0
  #   y = gain * x + offset
  #   y = stretch_gain * y + stretch_offset   (if stretch enabled)
  #   output = clamp(y * 256.0, 0, 65535)
  module ColorCorrection
    FLASH_TAG = 0x9209

    class << self
      # Load and parse the reference LUT JSON file.
      # Returns the parsed hash, or nil if the file is missing/invalid.
      def load_lut(lut_path)
        return nil unless File.exist?(lut_path)

        JSON.parse(File.read(lut_path))
      rescue JSON::ParserError, Errno::ENOENT => e
        Util.warn("Failed to load color correction LUT #{lut_path}: #{e.message}")
        nil
      end

      # Select the effective linear + stretch params for the given flash state.
      #
      # Looks up camera-specific params from the LUT's cameras dict.
      # Falls back to top-level linear/stretch keys for older LUT versions.
      #
      # Returns { params: { "R" => { gain:, offset: }, ... }, stretch: { gains: [...], offsets: [...] } }
      # or nil if no params are available.
      def select_params(lut, flash_fired, camera: "DC120")
        return nil unless lut

        group = flash_fired ? "flash_params" : "nonflash_params"

        # v20+: camera-specific params
        if lut["cameras"] && lut["cameras"][camera]
          camera_params = lut["cameras"][camera]
          group_data = camera_params[group]
          return nil unless group_data

          return build_result(group_data["linear"], group_data["stretch"])
        end

        # Older format: top-level linear/stretch
        if lut["params"] && lut["stretch"]
          return build_result(lut["params"], lut["stretch"])
        end

        nil
      end

      # Apply color correction to a 16-bit RGB image.
      #
      # Image is [[ [r,g,b], [r,g,b], ... ], [ ... ], ...] (array of rows of RGB triplets).
      # Returns a new image array with corrected values.
      def apply(image, params, stretch_params)
        return image unless params

        # Precompute channel constants
        r_gain = params["R"]["gain"].to_f
        g_gain = params["G"]["gain"].to_f
        b_gain = params["B"]["gain"].to_f
        r_offset = params["R"]["offset"].to_f
        g_offset = params["G"]["offset"].to_f
        b_offset = params["B"]["offset"].to_f

        stretch_gains = stretch_params&.dig("gains")&.map(&:to_f)
        stretch_offsets = stretch_params&.dig("offsets")&.map(&:to_f)
        do_stretch = !stretch_gains.nil? && !stretch_offsets.nil?

        # Precompute constants
        inv_256 = 1.0 / 256.0
        mul_256 = 256.0

        # Stretch constants (if enabled)
        if do_stretch
          rs_gain = stretch_gains[0]
          rs_off = stretch_offsets[0]
          gs_gain = stretch_gains[1]
          gs_off = stretch_offsets[1]
          bs_gain = stretch_gains[2]
          bs_off = stretch_offsets[2]
        end

        height = image.length
        width = image[0].length
        total = height * width

        # Flatten input image to 1D array for faster access
        flat = Array.new(total * 3)
        idx = 0
        y = 0
        while y < height
          row = image[y]
          x = 0
          while x < width
            flat[idx] = row[x][0]
            flat[idx + 1] = row[x][1]
            flat[idx + 2] = row[x][2]
            idx += 3
            x += 1
          end
          y += 1
        end

        # Process all pixels
        y = 0
        while y < height
          row = image[y]
          x = 0
          base = y * width * 3
          while x < width
            i = base + x * 3

            # R channel
            val = flat[i]
            x_float = val * inv_256
            y_float = r_gain * x_float + r_offset
            if do_stretch
              y_float = rs_gain * y_float + rs_off
            end
            v = (y_float * mul_256).round
            v = 0 if v < 0
            v = 65535 if v > 65535
            row[x][0] = v

            # G channel
            val = flat[i + 1]
            x_float = val * inv_256
            y_float = g_gain * x_float + g_offset
            if do_stretch
              y_float = gs_gain * y_float + gs_off
            end
            v = (y_float * mul_256).round
            v = 0 if v < 0
            v = 65535 if v > 65535
            row[x][1] = v

            # B channel
            val = flat[i + 2]
            x_float = val * inv_256
            y_float = b_gain * x_float + b_offset
            if do_stretch
              y_float = bs_gain * y_float + bs_off
            end
            v = (y_float * mul_256).round
            v = 0 if v < 0
            v = 65535 if v > 65535
            row[x][2] = v

            x += 1
          end
          y += 1
        end

        image
      end
    end

    private

    def self.build_result(linear, stretch)
      return nil unless linear

      params = {}
      linear.each do |channel, p|
        params[channel] = { "gain" => p["gain"].to_f, "offset" => p["offset"].to_f }
      end

      stretch_data = nil
      if stretch
        stretch_data = {
          "gains" => stretch["gains"].map(&:to_f),
          "offsets" => stretch["offsets"].map(&:to_f)
        }
      end

      { params: params, stretch: stretch_data }
    end
  end
end