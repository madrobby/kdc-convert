# frozen_string_literal: true

require "optparse"
require_relative "kdc/tiff_parser"
require_relative "kdc/decoders"
require_relative "kdc/demosaic"
require_relative "kdc/converter"
require_relative "kdc/tiff_writer"
require_relative "kdc/png_writer"
require_relative "kdc/util"

module KDC
  # Main entry point for KDC conversion
  class App
    def self.run(args)
      opts = parse_options(args)
      if opts[:help]
        print_usage
        return 0
      end

      mode = opts[:convert] ? :convert : :metadata
      run_mode(mode, opts)
    end

    def self.parse_options(args)
      opts = {
        verbose: false,
        convert: false,
        metadata: false,
        sharpen: nil,
        no_color_correction: false,
        output: nil,
        format: nil,
        kdc_file: nil,
        help: false,
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: kdc [options] <file.kdc>"

        o.on("-m", "--metadata", "Show KDC metadata") { opts[:metadata] = true }
        o.on("-c", "--convert", "Convert KDC to TIFF/PNG") { opts[:convert] = true }
        o.on("-o", "--output PATH", "Output file path") { |v| opts[:output] = v }
        o.on("-f", "--format {tif|png}", "Output format: tif or png (default: auto-detect from -o extension)") do |v|
          if %w[tif png].include?(v.downcase)
            opts[:format] = v.downcase
          else
            warn "Unknown format '#{v}', defaulting to tif"
            opts[:format] = "tif"
          end
        end
        o.on("-v", "--verbose", "Show step-by-step progress with timings") { opts[:verbose] = true }
        o.on("--no-color-correction", "Skip color correction step") { opts[:no_color_correction] = true }
        o.on("--sharpen[=r,a,t]", "Apply unsharp mask sharpening (opt-in)\n" \
                                   "Bare flag or =auto for medium strength\n" \
                                   "=r,a,t for custom radius,amount,threshold") do |v|
          opts[:sharpen] = parse_sharpen_value(v || "auto")
        end
        o.on("-h", "--help", "Show help") { opts[:help] = true }
      end

      remaining = parser.parse(args)
      opts[:kdc_file] = remaining.first
      opts
    end

    def self.run_mode(mode, opts)
      case mode
      when :metadata then run_metadata(opts)
      when :convert  then run_convert(opts)
      end
    end

    private

    def self.print_usage
      puts "kdc - Pure Ruby KDC file parser and converter (LibRaw port)"
      puts
      puts "Usage:"
      puts "  kdc <file.kdc>                    Show metadata"
      puts "  kdc -m <file.kdc>                 Show metadata"
      puts "  kdc -c <file.kdc> -o <output>     Convert to TIFF or PNG"
      puts "  kdc --help                        Show this help"
      puts
      puts "Options:"
      puts "  -m, --metadata            Show KDC metadata"
      puts "  -c, --convert             Convert KDC to image"
      puts "  -o, --output              Output file path"
      puts "  -f, --format              Output format: tif or png (default: auto-detect from -o extension)"
      puts "  -v, --verbose             Show step-by-step progress with timings"
      puts "  --no-color-correction     Skip color correction step"
      puts "  --sharpen[=r,a,t]         Apply unsharp mask sharpening (opt-in)"
      puts "                              bare flag or =auto for medium strength"
      puts "                              =r,a,t for custom radius,amount,threshold"
      puts "  -h, --help                Show help"
    end

    def self.run_metadata(opts)
      file = opts[:kdc_file]
      return 1 unless file && File.exist?(file)

      puts "Parsing #{file}..."
      metadata = KDC.parse_kdc(file)

      puts "\n=== KDC Metadata ==="
      puts "Camera: #{metadata.camera_model}"
      puts "Raw dimensions: #{metadata.raw_width}x#{metadata.raw_height}"
      puts "Pixel aspect: #{metadata.pixel_aspect}"
      puts "White level: #{metadata.white_level}"
      puts "Black level: #{metadata.black_level.inspect}"
      puts "Compression: #{metadata.compression}"

      puts "\n=== EXIF Tags ==="
      metadata.exif_tags.each do |tag, value|
        tag_name = format_tag_name(tag)
        puts "  #{tag_name}: #{value}"
      end

      0
    end

    def self.run_convert(opts)
      file = opts[:kdc_file]
      return 1 unless file && File.exist?(file)

      output = opts[:output]
      if output&.start_with?("-")
        warn "Warning: '#{output}' looks like an option, not a filename"
        output = nil
      end
      output ||= (file && file.sub(/\.kdc$/i, ".tif"))
      verbose = opts[:verbose]
      no_color_correction = opts[:no_color_correction]
      sharpen = opts[:sharpen]
      format = resolve_format(opts[:format], output)

      verbose_log(verbose, "Converting #{file} -> #{output} (#{format})")

      color_lut = if no_color_correction
                    nil
                  else
                    lut_path = File.join(File.dirname(__FILE__), "..", "reference_lut.json")
                    KDC::ColorCorrection.load_lut(lut_path)
                  end

      converter = KDC::Converter.new(file, color_lut: color_lut, sharpen: sharpen, verbose: verbose)
      begin
        case format
        when "png"
          converter.convert_to_png(output)
          bit_depth = 8
        else
          converter.convert_to_tiff(output)
          bit_depth = 16
        end

        file_size = File.size(output)
        img = converter.demosaiced_image
        actual_width = img[0].length
        actual_height = img.length

        verbose_log(verbose, "Saved to #{output} — #{format.upcase}, #{bit_depth}-bit, #{Util.format_resolution(actual_width, actual_height)}, #{Util.human_size(file_size)}")
        0
      rescue => e
        puts "Error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        1
      end
    end

    def self.resolve_format(format_flag, output)
      return format_flag if format_flag && %w[tif png].include?(format_flag)

      # Auto-detect from output extension
      ext = File.extname(output).downcase.delete(".")
      return "png" if ext == "png"
      "tif"
    end

    def self.format_tag_name(tag)
      case tag
      when 0x010F then "Make"
      when 0x0110 then "Model"
      when 0x0111 then "StripOffset"
      when 0x0117 then "StripByteCounts"
      when 0x0103 then "Compression"
      when 0x9209 then "Flash"
      when 0x829A then "ExposureTime"
      when 0x829D then "FNumber"
      when 0x9003 then "DateTimeOriginal"
      when 0x8827 then "ISO"
      when 0x920A then "FocalLength"
      when 0x8298 then "WhiteBalance"
      when 0x828F then "LightSource"
      when 0x8822 then "ExposureProgram"
      else "0x#{tag.to_s(16)}"
      end
    end

    def self.verbose_log(verbose, message)
      puts(message) if verbose
    end

    def self.parse_sharpen_value(str)
      return nil unless str
      if str == "auto" || str.empty?
        { radius: Sharpen::AUTO_RADIUS, amount: Sharpen::AUTO_AMOUNT, threshold: Sharpen::AUTO_THRESHOLD }
      else
        parts = str.split(",").map(&:to_f)
        {
          radius:    parts[0] && parts[0] > 0 ? parts[0] : Sharpen::AUTO_RADIUS,
          amount:    parts[1] && parts[1] > 0 ? parts[1] : Sharpen::AUTO_AMOUNT,
          threshold: parts[2] ? parts[2] : Sharpen::AUTO_THRESHOLD
        }
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit KDC::App.run(ARGV)
end
