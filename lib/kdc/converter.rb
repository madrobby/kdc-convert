# frozen_string_literal: true

require_relative "kdc_parser"
require_relative "dc120"
require_relative "dc50"
require_relative "demosaic"
require_relative "tiff_writer"
require_relative "png_writer"
require_relative "dng_writer"
require_relative "camera_data"
require_relative "color_correction"
require_relative "sharpen"
require_relative "resize"
require_relative "scale"
require_relative "dc50_processing"
require_relative "util"
require "tempfile"
require "fileutils"
require "pnglitch"

module KDC
  # DC120 KDC to TIFF converter
  # Complete pipeline: KDC -> raw Bayer -> demosaic -> resize -> TIFF
  class Converter
    # DC120 output dimensions (with aspect ratio correction)
    OUTPUT_WIDTH  = 1301  # 848 * 1.5346
    OUTPUT_HEIGHT = 976
    PIXEL_ASPECT  = 1.5345911949685533

    attr_reader :metadata, :raw_image, :demosaiced_image, :color_params, :sharpen_params, :flash_fired

    def initialize(kdc_path, color_lut: nil, sharpen: nil, remove_stuck_pixels: true, glitch: nil)
      @kdc_path = kdc_path
      @metadata = nil
      @raw_image = nil
      @demosaiced_image = nil
      @color_params = color_lut
      @sharpen_params = sharpen
      @flash_fired = nil
      @remove_stuck_pixels = remove_stuck_pixels
      @glitch_intensity = glitch
    end

    # Full conversion pipeline
    def convert
      @t0 = Util.now
      Util.reset_steps

      steps = [
        ["Parse metadata", :parse_metadata],
        ["Decode raw Bayer", :decode_raw],
        ["Apply black level", :apply_black_level],
        ["Demosaic", :demosaic_image],
        ["Scale to 16-bit", :scale_to_16bit],
        ["Correct aspect ratio", :correct_aspect_ratio],
        ["Color correction", :apply_color_correction]
      ]
      steps << ["Apply sharpening", :apply_sharpening] if @sharpen_params

      steps.each do |name, method|
        step_t = Util.now
        send(method)
        Util.step(name, Util.now - step_t)
      end

      @demosaiced_image
    end

    # Convert and save to TIFF file
    def convert_to_tiff(output_path, bit_depth: 8)
      image = convert
      image = scale_to_8bit(image) if bit_depth == 8

      # Build TIFF
      writer = TIFFWriter.new(image[0].length, image.length, bit_depth)
      writer.set_image_data(image)
      writer.setup_image_info

      if @metadata
        writer.set_camera_info(
          make: extract_make,
          model: extract_model
        )
        writer.set_metadata(@metadata)
      end

      step_t = Util.now
      writer.write(output_path)
      Util.step("Write TIFF", Util.now - step_t)
      log_total
      output_path
    end

    # Convert and save to PNG file
    def convert_to_png(output_path)
      image = convert
      if @metadata&.kdc_camera == :dc50
        # Apply gamma + auto_bright for 8-bit output (matching dcraw_emu -T default)
        image = apply_dc50_gamma_to_image(image)
      end
      png_image = scale_to_8bit(image)

      writer = PNGWriter.new(png_image[0].length, png_image.length)
      writer.set_image_data(png_image)

      step_t = Util.now
      if @glitch_intensity && @glitch_intensity > 0
        apply_png_glitch(writer, output_path, @glitch_intensity)
        Util.step("Write PNG + glitch", Util.now - step_t)
      else
        writer.write(output_path)
        Util.step("Write PNG", Util.now - step_t)
      end
      log_total
      output_path
    end

    # Convert and save to DNG file
    def convert_to_dng(output_path)
      @t0 = Util.now
      Util.reset_steps

      step_t = Util.now
      parse_metadata
      Util.step("Parse metadata", Util.now - step_t)

      step_t = Util.now
      decode_raw
      Util.step("Decode raw Bayer", Util.now - step_t)

      camera = @metadata.kdc_camera
      base = CameraData::COLOR_MATRICES[camera] || CameraData::COLOR_MATRICES[:dc120]
      cam_data = base.dup

      white_level = @metadata.kdc_white_level || 255
      as_shot_neutral = compute_as_shot_neutral

      step_t = Util.now
      thumbnail_data = extract_thumbnail
      Util.step("Extract thumbnail", Util.now - step_t)

      writer = DNGWriter.new(
        @raw_image[0].length, @raw_image.length,
        cam_data,
        white_level: white_level,
        as_shot_neutral: as_shot_neutral,
        make: extract_make,
        model: extract_model,
        thumbnail: thumbnail_data
      )
      writer.set_raw_data(@raw_image)

      writer.set_exif(
        exposure_time: @metadata&.exposure_time,
        f_number: @metadata&.f_number,
        iso: @metadata&.iso,
        focal_length: @metadata&.focal_length,
        date_time_original: @metadata&.date_time_original
      )

      step_t = Util.now
      writer.write(output_path)
      Util.step("Write DNG", Util.now - step_t)
      log_total
      output_path
    end

    private

    def log_total
      Util.log("Total: #{Util.format_duration(Util.now - @t0)}")
      Util.log("")
    end

    # Apply PNG glitch effect using pnglitch gem
    # Writes initial PNG to tempfile, glitches, saves to output
    def apply_png_glitch(writer, output_path, intensity)
      tmp_dir = File.join(File.dirname(__FILE__), "..", "..", "tmp")
      FileUtils.mkdir_p(tmp_dir)

      tempfile = Tempfile.new(["kdc_glitch", ".png"], tmp_dir)
      begin
        writer.write(tempfile.path)

        PNGlitch.open(tempfile.path) do |png|
          apply_glitch_techniques(png, intensity)
          png.save(output_path)
        end
      ensure
        tempfile.close!
      end

      output_path
    end

    # Each technique independently has a chance of occurring based on intensity
    def apply_glitch_techniques(png, intensity)
      srand
      chance = 0.5+(intensity/2) / 100.0

      png.change_all_filters :paeth

      glitch_graft(png, intensity)      if rand < chance
      glitch_replace(png, intensity)    if rand < chance
      glitch_transpose(png, intensity)  if rand < chance

      #glitch_filters(png, intensity)
      glitch_defect(png, intensity)     if rand < chance
      glitch_compressed(png, intensity) if rand < chance
    end

    def glitch_filters(png, intensity)
      chance = intensity / 100.0

      png.each_scanline do |scanline|
        scanline.change_filter(rand(4).round) if rand < chance
      end
    end

    # Apply wrong filter type to random scanlines (safe, always valid PNG)
    def glitch_graft(png, intensity)
      total = png.height
      count = (total * intensity / 100.0).round
      count = [count, 1].max

      indices = (0...total).to_a.sample(count)
      png.each_scanline do |scanline|
        scanline.graft(rand(5)) if indices.include?(scanline.index)
      end
    end

    # Randomly overwrite bytes in filtered data
    def glitch_replace(png, intensity)
      range = (intensity / 100.0 * 50).round
      range = [range, 1].max
      png.glitch do |data|
        range.times { data[rand(data.size)] = "x" }
        data
      end
    end

    # Rearrange chunks of filtered data
    def glitch_transpose(png, _intensity)
      png.glitch do |data|
        x = data.size / 4
        data[0, x] + data[x * 2, x] + data[x * 1, x] + data[x * 3..-1]
        data
      end
    end

    # Randomly change bytes in filtered data
    def glitch_defect(png, intensity)
#       png.each_scanline do |scanline|
#         scanline.change_filter 4
#       end

      range = [intensity, 1].max
      png.glitch do |data|
        range.times { data[rand(data.size)] = "" }
        data
      end
    end

    # Glitch the compressed data (most destructive)
    def glitch_compressed(png, intensity)
      range = [intensity, 1].max
      png.glitch_after_compress do |data|
        range.times { data[rand(data.size)] = "x" }
        data
      end
    end

    # Extract JPEG thumbnail from KDC file
    # The thumbnail JPEG data is in the second IFD with correct offset/size,
    # but dimensions are in the first IFD.
    def extract_thumbnail
      return nil unless @metadata&.ifds&.first&.entries

      first_entries = @metadata.ifds.first.entries
      second_ifd = @metadata.second_ifd
      return nil unless second_ifd

      second_entries = second_ifd.entries

      # Thumbnail dimensions from first IFD (80x60)
      width_entry = first_entries.find { |e| e.tag == 0x0100 }  # TAG_IMAGE_WIDTH
      height_entry = first_entries.find { |e| e.tag == 0x0101 } # TAG_IMAGE_LENGTH

      # Thumbnail offset/size/compression from second IFD (correct values)
      offset_entry = second_entries.find { |e| e.tag == 0x0111 } # TAG_STRIP_OFFSETS
      bytes_entry = second_entries.find { |e| e.tag == 0x0117 }  # TAG_STRIP_BYTE_COUNTS
      comp_entry = second_entries.find { |e| e.tag == 0x0103 }   # TAG_COMPRESSION
      samples_entry = second_entries.find { |e| e.tag == 0x0115 } # TAG_SAMPLES_PER_PIXEL
      photometric_entry = second_entries.find { |e| e.tag == 0x0106 } # TAG_PHOTOMETRIC_INTERP

      return nil unless offset_entry&.value && bytes_entry&.value

      thumb_offset = offset_entry.value.is_a?(Array) ? offset_entry.value.first : offset_entry.value
      thumb_bytes = bytes_entry.value.is_a?(Array) ? bytes_entry.value.first : bytes_entry.value
      thumb_width = width_entry&.value || 80
      thumb_height = height_entry&.value || 60
      thumb_comp = comp_entry&.value || 7 # JPEG
      thumb_samples = samples_entry&.value || 3
      thumb_photometric = photometric_entry&.value || 2 # RGB

      # Read thumbnail data from file
      File.open(@kdc_path, "rb") do |f|
        f.seek(thumb_offset)
        data = f.read(thumb_bytes)
        return nil unless data && data.bytesize == thumb_bytes

        # KDC stores JPEG thumbnail data byte-swapped (each 16-bit word swapped); fix it
        # Swap bytes within each 16-bit word to get correct JPEG byte order
        data = data.unpack("n*").map { |w| (w >> 8) | ((w & 0xFF) << 8) }.pack("n*") if thumb_comp == 7

        # Trim to actual JPEG data (SOI to EOI) - KDC may include padding bytes
        soi = data.index("\xFF\xD8".b)
        eoi = data.index("\xFF\xD9".b, soi) if soi
        data = data[soi, eoi - soi + 2] if soi && eoi

        {
          data: data,
          width: thumb_width,
          height: thumb_height,
          compression: thumb_comp,
          samples_per_pixel: thumb_samples,
          photometric_interpretation: 6  # YCbCr for JPEG
        }
      end
    end

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
      case @metadata.kdc_camera
      when :dc120
        @raw_image = DC120Decoder.new(
          @kdc_path,
          compressed: @metadata.compression == 7,
          data_offset: @metadata.kdc_data_offset,
          data_size: @metadata.kdc_data_size,
          remove_stuck_pixels: @remove_stuck_pixels
        ).decode
      when :dc50
        flat = DC50Decoder.new(
          @kdc_path,
          data_offset: @metadata.kdc_data_offset,
          data_size: @metadata.kdc_data_size,
          remove_stuck_pixels: @remove_stuck_pixels,
          kodak_cbpp: @metadata.kdc_compressed_bits_per_pixel
        ).decode
        @raw_image = flat.each_slice(@metadata.kdc_raw_width).to_a
      else
        raise TIFFError, "Unsupported camera: #{@metadata.kdc_camera}"
      end
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
      Scale.scale_16bit_in_place!(@demosaiced_image, white_level)
    end

    # Scale 16-bit image to 8-bit (for PNG output)
    def scale_to_8bit(image)
      return nil unless image

      Scale.to_8bit(image)
    end

    # Step 6: Apply aspect ratio correction (stretch width)
    def correct_aspect_ratio
      return unless @demosaiced_image

      aspect = @metadata.kdc_pixel_aspect
      return if aspect == 1.0

      src_width = @demosaiced_image[0].length
      src_height = @demosaiced_image.length

      # Calculate target dimensions
      target_width = (src_width * aspect).round
      target_height = src_height

      # Simple bilinear resize (pure Ruby)
      @demosaiced_image = resize_bilinear(@demosaiced_image, target_width, target_height)
    end

    # Step 7: Apply color correction (flash-aware, camera-specific)
    def apply_color_correction
      if @metadata&.kdc_camera == :dc50
        @demosaiced_image = DC50Processing.apply_matrix(@demosaiced_image)
        return
      end

      return unless @color_params

      flash_tag = @metadata&.flash&.to_i || 0
      @flash_fired = (flash_tag & 1) == 1

      effective = ColorCorrection.select_params(
        @color_params,
        @flash_fired,
        camera: @metadata&.kdc_camera&.to_s&.upcase || "DC120"
      )

      return unless effective

      @demosaiced_image = ColorCorrection.apply(
        @demosaiced_image,
        effective[:params],
        effective[:stretch]
      )
    end

    # Apply DC50 auto-bright + gamma (for 8-bit output only; matrix already applied)
    def apply_dc50_gamma_to_image(image)
      DC50Processing.apply_gamma(image)
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
      Resize.bilinear(image, target_width, target_height)
    end

    # Extract Make from metadata
    def extract_make
      @metadata&.make || "Kodak"
    end

    # Extract Model from metadata
    def extract_model
      @metadata&.model || "Unknown"
    end

    # Compute AsShotNeutral for DNG from LUT gains or fallback defaults
    def compute_as_shot_neutral
      flash_tag = @metadata&.flash&.to_i || 0
      flash_fired = (flash_tag & 1) == 1

      if @color_params
        camera_name = @metadata&.kdc_camera&.to_s&.upcase || "DC120"
        params = @color_params.dig("cameras", camera_name, flash_fired ? "flash_params" : "nonflash_params")
        if params && (gains = params["linear"])
          r_gain = gains.dig("R", "gain") || 1.0
          g_gain = gains.dig("G", "gain") || 1.0
          b_gain = gains.dig("B", "gain") || 1.0
          inv = [1.0 / r_gain, 1.0 / g_gain, 1.0 / b_gain]
          sum = inv.sum
          return inv.map { |v| v * inv.length / sum } if sum > 0
        end
      end

      flash_fired ? [1.0, 1.0, 1.0] : [1.0, 1.0, 1.0]
    end

  end
end
