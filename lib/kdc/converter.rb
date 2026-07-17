# frozen_string_literal: true

require_relative "kdc_parser"
require_relative "dc120"
require_relative "dc50"
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

      writer.write(output_path)
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
      scale_factor = 65535.0 / white_level
      clamp_max = 65535

      height = @demosaiced_image.length
      width = @demosaiced_image[0].length
      y = 0
      while y < height
        row = @demosaiced_image[y]
        x = 0
        while x < width
          pixel = row[x]
          r = (pixel[0] * scale_factor).round
          g = (pixel[1] * scale_factor).round
          b = (pixel[2] * scale_factor).round
          r = clamp_max if r > clamp_max
          g = clamp_max if g > clamp_max
          b = clamp_max if b > clamp_max
          pixel[0] = r
          pixel[1] = g
          pixel[2] = b
          x += 1
        end
        y += 1
      end
    end

    # Scale 16-bit image to 8-bit (for PNG output)
    def scale_to_8bit(image)
      return nil unless image

      height = image.length
      width = image[0].length

      # Preallocate flat output array
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

      # Reshape to 2D
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
        apply_dc50_matrix
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

# DC50 color matrix from KDC tag 0x9218 (embedded in file), libraw's rgb_cam.
# 3×3 matrix: raw camera RGB → sRGB (output_color=1).
DC50_SRGB_MATRIX = [
  [ 1.812500, -0.336500, -0.476000 ],
  [ -0.435000,  1.852000, -0.417000 ],
  [ -0.676000, -1.393000,  3.069000 ]
].freeze

# Step 7a: Apply DC50 color matrix (KDC tag 0x9218) with soft-clamp for negatives
    def apply_dc50_matrix
      height = @demosaiced_image.length
      width = @demosaiced_image[0].length
      mat = DC50_SRGB_MATRIX

      # Pre-compute interpolated B-channel (demosaiced raw B) at G-pixels
      # Use 4 diagonal B-pixel neighbors in GRBG pattern
      b_at_g = {}
      height.times do |y|
        width.times do |x|
          next unless (x + y) % 2 == 1  # G-pixel in GRBG
          nb = 0; cnt = 0
          # Diagonal neighbors are B-pixels in GRBG
          [[-1,-1],[-1,1],[1,-1],[1,1]].each do |dx,dy|
            nx, ny = x+dx, y+dy
            if nx >= 0 && nx < width && ny >= 0 && ny < height
              _, _, b_raw = @demosaiced_image[ny][nx]
              nb += b_raw
              cnt += 1
            end
          end
          b_at_g[[x,y]] = cnt > 0 ? nb / cnt : 0
        end
      end

      srgb = Array.new(height) do |y|
        Array.new(width) do |x|
          r, g, b = @demosaiced_image[y][x]
          rs = mat[0][0] * r + mat[0][1] * g + mat[0][2] * b
          gs = mat[1][0] * r + mat[1][1] * g + mat[1][2] * b
          bs = mat[2][0] * r + mat[2][1] * g + mat[2][2] * b

          # At G-pixels where B goes negative, use interpolated B from diagonal B-pixels
          if bs < 0 && (x + y) % 2 == 1
            b_interp = b_at_g[[x,y]]
            # Apply only the B-coefficient (mat[2][2] = 3.069) since R,G contributions are unknown
            bs = mat[2][2] * b_interp
          end
          # Final safety clamp
          rs = [rs, 0].max
          gs = [gs, 0].max
          bs = [bs, 0].max
          [rs, gs, bs].map { |v| v.round }.map { |v| [v, 65535].min }
        end
      end

      @demosaiced_image = srgb
    end

# Step 7b: Apply DC50 auto-bright + gamma (for 8-bit output only; matrix already applied)
    def apply_dc50_gamma_to_image(image)
      height = image.length
      width = image[0].length

      # Step 2: histogram from matrix‑multiplied values (libraw convert_to_rgb_loop)
      hist = Array.new(3) { Array.new(8192, 0) }
      height.times do |y|
        width.times do |x|
          image[y][x].each_with_index do |v, c|
            idx = v >> 3
            hist[c][idx] += 1 if idx < 8192
          end
        end
      end

      # Step 3: auto‑brightness (libraw: per-channel t_white = max across channels, starting from 0)
      total_pixels = height * width
      thr = (total_pixels * 0.01).ceil
      t_white = [0, 0, 0]
      3.times do |c|
        accum = 0
        8191.downto(33) do |b|
          accum += hist[c][b]
          if accum > thr
            t_white[c] = b
            break
          end
        end
      end
      # Use single t_white = max across channels (libraw behavior in write_ppm_tiff)
      imax_val = t_white.max << 3
      imax = [imax_val] * 3

      # Step 4: libraw gamma_curve parameters (mode=0 → compute g[2..5])
      pwr = 0.45
      ts  = 4.5
      bnd = [0.0, 1.0]
      48.times do
        g2 = (bnd[0] + bnd[1]) / 2.0
        c = ((g2 / ts) ** (-pwr) - 1) / pwr - 1.0 / g2
        c > -1 ? (bnd[1] = g2) : (bnd[0] = g2)
      end
      g2 = (bnd[0] + bnd[1]) / 2.0
      g3 = g2 / ts
      g4 = g2 * (1.0 / pwr - 1)

      # Step 5: apply gamma LUT (libraw mode=1 forward transform)
      pre = 65536.0
      out_max = 65535
      height.times do |y|
        width.times do |x|
          image[y][x] = image[y][x].map.with_index do |v, c|
            r = v.to_f / imax[c]
            if r < 1.0
              gv = r < g3 ? r * ts : r ** pwr * (1 + g4) - g4
              out = (gv * pre).round
              out > out_max ? out_max : out
            else
              out_max
            end
          end
        end
      end
      image
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

    # Extract Make from metadata
    def extract_make
      @metadata&.make || "Kodak"
    end

    # Extract Model from metadata
    def extract_model
      @metadata&.model || "Unknown"
    end

  end
end
