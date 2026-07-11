# frozen_string_literal: true

require_relative "kdc_parser"
require_relative "decoders"
require_relative "demosaic"
require_relative "tiff_writer"
require_relative "png_writer"
require_relative "color_correction"
require_relative "sharpen"
require_relative "util"

module KDC
  # DC120 KDC to TIFF converter
  # Complete pipeline: KDC -> raw Bayer -> demosaic -> resize -> TIFF
  class Converter
    # DC120 output dimensions (with aspect ratio correction)
    OUTPUT_WIDTH  = 1301  # 848 * 1.5346
    OUTPUT_HEIGHT = 976
    PIXEL_ASPECT  = 1.5345911949685533

    attr_reader :metadata, :raw_image, :demosaiced_image, :color_params, :sharpen_params, :flash_fired

    def initialize(kdc_path, color_lut: nil, sharpen: nil, remove_stuck_pixels: true)
      @kdc_path = kdc_path
      @metadata = nil
      @raw_image = nil
      @demosaiced_image = nil
      @color_params = color_lut
      @sharpen_params = sharpen
      @flash_fired = nil
      @remove_stuck_pixels = remove_stuck_pixels
    end

    # Full conversion pipeline
    def convert
      t0 = Util.now

      steps = [
        ["Parse metadata", :parse_metadata],
        ["Decode raw Bayer", :decode_raw],
        ["Apply black level", :apply_black_level],
        ["Demosaic", :demosaic_image],
        ["Scale to 16-bit", :scale_to_16bit],
        ["Correct aspect ratio", :correct_aspect_ratio],
        ["Color correction", :apply_color_correction],
        ["Apply sharpening", :apply_sharpening]
      ]

      steps.each_with_index do |(name, method), i|
        step_t = Util.now
        send(method)
        elapsed = Util.now - step_t
        Util.log("Step #{i + 1}/#{steps.length}: #{name} ... #{Util.format_duration(elapsed)}")
      end

      total = Util.now - t0
      Util.log("Total: #{Util.format_duration(total)}")
      Util.log("")

      @demosaiced_image
    end

    # Convert and save to TIFF file
    def convert_to_tiff(output_path)
      image = convert

      # Build TIFF
      writer = TIFFWriter.new(image[0].length, image.length)
      writer.set_image_data(image)
      writer.setup_image_info

      if @metadata
        writer.set_camera_info(
          make: extract_make,
          model: extract_model
        )
        writer.set_metadata(@metadata)
      end

      writer.write(output_path)
      output_path
    end

    # Convert and save to PNG file
    def convert_to_png(output_path)
      image = convert
      png_image = scale_to_8bit(image)

      writer = PNGWriter.new(png_image[0].length, png_image.length)
      writer.set_image_data(png_image)
      writer.write(output_path)
      output_path
    end

    private

    # Step 1: Parse KDC metadata
    def parse_metadata
      @metadata = KDC.parse_kdc(@kdc_path)

      camera_name = @metadata.kdc_camera == :dc120 ? "DC120" : @metadata.kdc_camera == :dc50 ? "DC50" : "Unknown"
      quality_str = Util.format_quality(@metadata.compression, @metadata.kdc_quality)
      flash_tag = @metadata.flash&.to_i || 0
      flash_str = (flash_tag & 1) == 1 ? "on" : "off"

      exposure_str = format_exposure_line(@metadata)
      Util.log("")
      if exposure_str
        Util.log("KDC format: #{camera_name}, #{Util.format_resolution(@metadata.kdc_raw_width, @metadata.kdc_raw_height)}, #{exposure_str}, #{quality_str}, flash #{flash_str}")
      else
        Util.log("KDC format: #{camera_name}, #{Util.format_resolution(@metadata.kdc_raw_width, @metadata.kdc_raw_height)}, #{quality_str}, flash #{flash_str}")
      end
    end

    # Build a compact exposure segment: "24mm ƒ/2.5 1/250s"
    # Missing values are silently omitted; returns nil if all three are missing.
    def format_exposure_line(metadata)
      parts = []

      if metadata.focal_length
        parts << "#{metadata.focal_length.to_i}mm"
      end

      if metadata.f_number
        parts << "ƒ/#{metadata.f_number.to_f}"
      end

      if metadata.exposure_time
        if metadata.exposure_time < 1
          ratio = 1.0 / metadata.exposure_time.to_f
          parts << "1/#{[1, (ratio.round)].max}s"
        else
          parts << "#{metadata.exposure_time.to_f}s"
        end
      end

      parts.empty? ? nil : parts.join(" ")
    end

    # Step 2: Decode raw Bayer data
    def decode_raw
      @raw_image = DC120Decoder.new(
        @kdc_path,
        compressed: @metadata.compression == 7,
        data_offset: @metadata.kdc_data_offset,
        data_size: @metadata.kdc_data_size,
        remove_stuck_pixels: @remove_stuck_pixels
      ).decode
    end

    # Step 3: Apply black level subtraction
    def apply_black_level
      black_level = @metadata.kdc_black_level[0]

      height = @raw_image.length
      width = @raw_image[0].length

      height.times do |y|
        width.times do |x|
          val = @raw_image[y][x] - black_level
          @raw_image[y][x] = [val, 0].max
        end
      end
    end

    # Step 4: Demosaic using Menon2007
    def demosaic_image
      @demosaiced_image = Menon2007.demosaic(@raw_image, "GRBG")
    end

    # Step 5: Scale to fill 16-bit range using white level from metadata
    def scale_to_16bit
      return unless @demosaiced_image

      white_level = @metadata&.kdc_white_level || 510
      scale_factor = 65535.0 / white_level

      height = @demosaiced_image.length
      width = @demosaiced_image[0].length
      height.times do |y|
        width.times do |x|
          r, g, b = @demosaiced_image[y][x]
          @demosaiced_image[y][x] = [
            (r * scale_factor).round,
            (g * scale_factor).round,
            (b * scale_factor).round
          ].map { |v| [v, 65535].min }
        end
      end
    end

    # Scale 16-bit image to 8-bit (for PNG output)
    def scale_to_8bit(image)
      return nil unless image

      height = image.length
      width = image[0].length
      Array.new(height) do |y|
        Array.new(width) do |x|
          r, g, b = image[y][x]
          [
            (r / 256).round,
            (g / 256).round,
            (b / 256).round
          ].map { |v| [v, 255].min }
        end
      end
    end

    # Step 6: Apply aspect ratio correction (stretch width)
    def correct_aspect_ratio
      return unless @demosaiced_image

      src_width = @demosaiced_image[0].length

      # Calculate target dimensions
      target_height = OUTPUT_HEIGHT
      target_width = (src_width * @metadata.kdc_pixel_aspect).round

      # Simple bilinear resize (pure Ruby)
      @demosaiced_image = resize_bilinear(@demosaiced_image, target_width, target_height)
    end

    # Step 7: Apply color correction (flash-aware, camera-specific)
    def apply_color_correction
      return unless @color_params

      flash_tag = @metadata&.flash&.to_i || 0
      @flash_fired = (flash_tag & 1) == 1

      effective = ColorCorrection.select_params(
        @color_params,
        @flash_fired,
        camera: @metadata&.kdc_camera&.to_s || "DC120"
      )

      return unless effective

      @demosaiced_image = ColorCorrection.apply(
        @demosaiced_image,
        effective[:params],
        effective[:stretch]
      )
    end

    # Step 8: Apply unsharp mask sharpening (opt-in)
    def apply_sharpening
      return unless @sharpen_params

      Util.log("Sharpen: radius=#{@sharpen_params[:radius]}, amount=#{@sharpen_params[:amount]}, threshold=#{@sharpen_params[:threshold]}")
      @demosaiced_image = Sharpen.unsharp_mask(
        @demosaiced_image,
        radius: @sharpen_params[:radius],
        amount: @sharpen_params[:amount],
        threshold: @sharpen_params[:threshold]
      )
    end

    # Bilinear resize (pure Ruby implementation)
    def resize_bilinear(image, target_width, target_height)
      src_height = image.length
      src_width = image[0].length

      x_ratio = src_width.to_f / target_width
      y_ratio = src_height.to_f / target_height

      Array.new(target_height) do |ty|
        Array.new(target_width) do |tx|
          # Source coordinates
          src_x = tx * x_ratio
          src_y = ty * y_ratio

          x0 = src_x.floor
          y0 = src_y.floor
          x1 = [x0 + 1, src_width - 1].min
          y1 = [y0 + 1, src_height - 1].min

          # Fractional parts
          fx = src_x - x0
          fy = src_y - y0

          # Interpolate each channel
          rgb = [0, 0, 0]
          3.times do |c|
            v00 = image[y0][x0][c].to_f
            v01 = image[y0][x1][c].to_f
            v10 = image[y1][x0][c].to_f
            v11 = image[y1][x1][c].to_f

            v0 = v00 * (1 - fx) + v01 * fx
            v1 = v10 * (1 - fx) + v11 * fx
            v = v0 * (1 - fy) + v1 * fy

            rgb[c] = [v.round, 65535].min
          end

          rgb
        end
      end
    end

    # Extract Make from metadata
    def extract_make
      @metadata&.make || "Kodak"
    end

    # Extract Model from metadata
    def extract_model
      @metadata&.model || "DC120"
    end

  end
end
