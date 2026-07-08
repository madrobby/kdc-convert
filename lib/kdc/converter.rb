# frozen_string_literal: true

require_relative "tiff_parser"
require_relative "decoders"
require_relative "demosaic"
require_relative "tiff_writer"
require_relative "color_correction"

module KDC
  # DC120 KDC to TIFF converter
  # Complete pipeline: KDC -> raw Bayer -> demosaic -> resize -> TIFF
  class Converter
    # DC120 output dimensions (with aspect ratio correction)
    OUTPUT_WIDTH  = 1301  # 848 * 1.5346
    OUTPUT_HEIGHT = 976
    PIXEL_ASPECT  = 1.5345911949685533

    attr_reader :metadata, :raw_image, :demosaiced_image, :color_params, :flash_fired

    def initialize(kdc_path, color_lut: nil)
      @kdc_path = kdc_path
      @metadata = nil
      @raw_image = nil
      @demosaiced_image = nil
      @color_params = color_lut
      @flash_fired = nil
    end

    # Full conversion pipeline
    def convert
      # Step 1: Parse KDC metadata
      parse_metadata

      # Step 2: Decode raw Bayer data
      decode_raw

      # Step 3: Apply black level
      apply_black_level

      # Step 4: Demosaic (Menon2007)
      demosaic_image

      # Step 5: Scale to 16-bit range
      scale_to_16bit

      # Step 6: Apply aspect ratio correction
      correct_aspect_ratio

      # Step 7: Apply color correction
      apply_color_correction

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
      end

      writer.write(output_path)
      output_path
    end

    private

    # Step 1: Parse KDC metadata
    def parse_metadata
      @metadata = KDC.parse_kdc(@kdc_path)
    end

    # Step 2: Decode raw Bayer data
    def decode_raw
      @raw_image = DC120Decoder.new(@kdc_path, compressed: true).decode
    end

    # Step 3: Apply black level subtraction
    def apply_black_level
      black_level = @metadata.black_level[0]

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

      white_level = @metadata&.white_level || 510
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

    # Step 6: Apply aspect ratio correction (stretch width)
    def correct_aspect_ratio
      return unless @demosaiced_image

      src_height = @demosaiced_image.length
      src_width = @demosaiced_image[0].length

      # Calculate target dimensions
      target_height = OUTPUT_HEIGHT
      target_width = (src_width * PIXEL_ASPECT).round

      # Simple bilinear resize (pure Ruby)
      @demosaiced_image = resize_bilinear(@demosaiced_image, target_width, target_height)
    end

    # Step 7: Apply color correction (flash-aware, camera-specific)
    def apply_color_correction
      return unless @color_params

      flash_tag = @metadata&.exif_tags&.dig(0x9209)&.to_i || 0
      @flash_fired = (flash_tag & 1) == 1

      effective = ColorCorrection.select_params(
        @color_params,
        @flash_fired,
        camera: @metadata&.camera_model&.to_s || "DC120"
      )

      return unless effective

      @demosaiced_image = ColorCorrection.apply(
        @demosaiced_image,
        effective[:params],
        effective[:stretch]
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
      if @metadata&.exif_tags
        @metadata.exif_tags[0x010F] || "Kodak"
      else
        "Kodak"
      end
    end

    # Extract Model from metadata
    def extract_model
      if @metadata&.exif_tags
        @metadata.exif_tags[0x0110] || "DC120"
      else
        "DC120"
      end
    end

    # Add EXIF metadata to TIFF writer
    def add_exif_metadata(writer)
      return unless @metadata&.exif_tags

      tags = @metadata.exif_tags

      # ExposureTime (0x829A)
      if tags[0x829A]
        num, denom = tags[0x829A].to_s.split("/").map(&:to_i)
        writer.add_exif_entry(0x829A, TIFFWriter::TIFF_TYPE_RATIONAL, 1, [num, denom])
      end

      # FNumber (0x829D)
      if tags[0x829D]
        num, denom = tags[0x829D].to_s.split("/").map(&:to_i)
        writer.add_exif_entry(0x829D, TIFFWriter::TIFF_TYPE_RATIONAL, 1, [num, denom])
      end

      # DateTimeOriginal (0x9003)
      if tags[0x9003]
        writer.add_exif_entry(0x9003, TIFFWriter::TIFF_TYPE_ASCII, tags[0x9003].bytes.length + 1, tags[0x9003])
      end

      # ISO (0x8827)
      if tags[0x8827]
        writer.add_exif_entry(0x8827, TIFFWriter::TIFF_TYPE_SHORT, 1, tags[0x8827].to_i)
      end

      # Flash (0x9209)
      if tags[0x9209]
        writer.add_exif_entry(0x9209, TIFFWriter::TIFF_TYPE_SHORT, 1, tags[0x9209].to_i)
      end
    end
  end
end
