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
        warn "kdc2tiff: failed to load color correction LUT #{lut_path}: #{e.message}"
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

        gains = {}
        offsets = {}
        params.each do |channel, p|
          gains[channel] = p["gain"].to_f
          offsets[channel] = p["offset"].to_f
        end

        stretch_gains = stretch_params&.dig("gains")&.map(&:to_f)
        stretch_offsets = stretch_params&.dig("offsets")&.map(&:to_f)
        do_stretch = !stretch_gains.nil? && !stretch_offsets.nil?

        height = image.length
        width = image[0].length
        channels = ["R", "G", "B"]

        Array.new(height) do |y|
          Array.new(width) do |x|
            row_data = image[y][x]
            new_row = [0, 0, 0]

            3.times do |c|
              channel = channels[c]
              input_val = row_data[c].to_f

              # Step 1: convert 16-bit to float
              x_float = input_val / 256.0

              # Step 2: per-channel linear transform
              y_float = gains[channel] * x_float + offsets[channel]

              # Step 3: stretch (dynamic range extension)
              if do_stretch
                y_float = stretch_gains[c] * y_float + stretch_offsets[c]
              end

              # Step 4: back to 16-bit, clipped
              new_row[c] = [y_float * 256.0, 0].max.round
              new_row[c] = [new_row[c], 65535].min
            end

            new_row
          end
        end
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
