# frozen_string_literal: true

require_relative "kdc/tiff_parser"
require_relative "kdc/decoders"
require_relative "kdc/demosaic"
require_relative "kdc/converter"
require_relative "kdc/tiff_writer"

module KDC
  # Main entry point for KDC conversion
  class App
    def self.run(args)
      if args.empty? || args.include?("--help") || args.include?("-h")
        print_usage
        return 0
      end

      if args.include?("--metadata") || args.include?("-m")
        return run_metadata(args)
      end

      if args.include?("--convert") || args.include?("-c")
        return run_convert(args)
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
      puts "  kdc -c <file.kdc> -o <output.tif> Convert to TIFF"
      puts "  kdc --help                        Show this help"
      puts
      puts "Options:"
      puts "  -m, --metadata            Show KDC metadata"
      puts "  -c, --convert             Convert KDC to TIFF"
      puts "  -o, --output              Output file path"
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

    def self.run_convert(args)
      file = find_kdc_file(args)
      return 1 unless file

      output = find_output(args)
      output ||= file.sub(/\.kdc$/i, ".tif")

      no_color_correction = args.include?("--no-color-correction")

      puts "Converting #{file} -> #{output}"

      color_lut = if no_color_correction
                    nil
                  else
                    lut_path = File.join(File.dirname(__FILE__), "..", "reference_lut.json")
                    KDC::ColorCorrection.load_lut(lut_path)
                  end

      converter = KDC::Converter.new(file, color_lut: color_lut)
      begin
        converter.convert_to_tiff(output)
        puts "Saved to #{output}"
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

    def self.save_as_ppm(image, path)
      height = image.length
      width = image[0].length

      File.open(path, "wb") do |f|
        # P6 header (16-bit)
        f.write("P6\n#{width} #{height}\n65535\n")

        # Write RGB data
        height.times do |y|
          width.times do |x|
            r, g, b = image[y][x]
            f.write([r, g, b].pack("v*"))
          end
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit KDC::App.run(ARGV)
end
