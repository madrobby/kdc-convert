# frozen_string_literal: true

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
      if args.empty? || args.include?("--help") || args.include?("-h")
        print_usage
        return 0
      end

      verbose = args.delete("-v") || args.delete("--verbose")

      if args.include?("--metadata") || args.include?("-m")
        return run_metadata(args)
      end

      if args.include?("--convert") || args.include?("-c")
        return run_convert(args, verbose)
      end

      # Default: show metadata
      run_metadata(args)
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
      puts "  -h, --help                Show help"
    end

    def self.run_metadata(args)
      file = find_kdc_file(args)
      return 1 unless file

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

    def self.run_convert(args, verbose)
      file = find_kdc_file(args)
      return 1 unless file

      output = find_output(args)
      output ||= file.sub(/\.kdc$/i, ".tif")

      no_color_correction = args.include?("--no-color-correction")
      format = resolve_format(args, output)

      verbose_log(verbose, "Converting #{file} -> #{output} (#{format})")

      color_lut = if no_color_correction
                    nil
                  else
                    lut_path = File.join(File.dirname(__FILE__), "..", "reference_lut.json")
                    KDC::ColorCorrection.load_lut(lut_path)
                  end

      converter = KDC::Converter.new(file, color_lut: color_lut, verbose: verbose)
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

        verbose_log(verbose, "Saved to #{output} — #{format.upcase}, #{bit_depth}-bit, #{actual_width}x#{actual_height}, #{Util.human_size(file_size)}")
        0
      rescue => e
        puts "Error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        1
      end
    end

    def self.find_kdc_file(args)
      idx = args.index { |a| a.end_with?(".kdc") || a.end_with?(".KDC") }
      return nil unless idx

      file = args[idx]
      return nil unless File.exist?(file)

      file
    end

    def self.find_output(args)
      idx = args.index("-o") || args.index("--output")
      return nil unless idx && idx < args.length - 1

      args[idx + 1]
    end

    def self.resolve_format(args, output)
      # -f flag overrides everything
      format_idx = args.index("-f") || args.index("--format")
      if format_idx && format_idx < args.length - 1
        fmt = args[format_idx + 1].downcase
        return "png" if fmt == "png"
        return "tif" if fmt == "tif"
        warn "Unknown format '#{fmt}', defaulting to tif"
        return "tif"
      end

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
  end
end

if __FILE__ == $PROGRAM_NAME
  exit KDC::App.run(ARGV)
end
