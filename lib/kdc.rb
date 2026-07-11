# frozen_string_literal: true

require "optparse"
require_relative "kdc/kdc_parser"
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
          no_color: false,
          no_remove_stuck_pixels: false,
          output: nil,
          format: nil,
          output_explicit: false,
          format_explicit: false,
          kdc_file: nil,
          help: false,
        }

      parser = OptionParser.new do |o|
        o.banner = "Usage: kdc [options] <file.kdc>"

        o.on("-m", "--metadata", "Show KDC metadata") { opts[:metadata] = true }
        o.on("-c", "--convert", "Convert KDC to TIFF/PNG") { opts[:convert] = true }
        o.on("-o", "--output PATH", "Output file path") { |v| opts[:output] = v; opts[:output_explicit] = true }
        o.on("-f", "--format {tif|png}", "Output format: tif or png (default: auto-detect from -o extension)") do |v|
          opts[:format_explicit] = true
          if %w[tif png].include?(v.downcase)
            opts[:format] = v.downcase
          else
            Util.warn("Unknown format '#{v}', defaulting to tif")
            opts[:format] = "tif"
          end
        end
        o.on("-v", "--verbose", "Show step-by-step progress with timings") { opts[:verbose] = true }
        o.on("--no-color", "Disable colored output") { opts[:no_color] = true }
        o.on("--no-color-correction", "Skip color correction step") { opts[:no_color_correction] = true }
        o.on("--no-remove-stuck-pixels", "Skip stuck pixel removal after JPEG decode") { opts[:no_remove_stuck_pixels] = true }
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
      Util.verbose = opts[:verbose]
      Rainbow.enabled = !opts[:no_color]
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

      cols = 60
      opts = [
        ["-m, --metadata", "Show KDC metadata"],
        ["-c, --convert", "Convert KDC to image"],
        ["-o, --output PATH", "Output file path"],
        ["-f, --format {tif|png}", "Output format: tif or png (default: auto-detect from -o extension)"],
        ["-v, --verbose", "Show step-by-step progress with timings"],
        ["--no-color", "Disable colored output"],
        ["--no-color-correction", "Skip color correction step"],
        ["--no-remove-stuck-pixels", "Skip stuck pixel removal after JPEG decode"],
        ["--sharpen[=r,a,t]", "Apply unsharp mask sharpening (opt-in)\n" \
                               "    Bare flag or =auto for medium strength\n" \
                               "    =r,a,t for custom radius,amount,threshold"],
        ["-h, --help", "Show help"],
      ]

      opts.each do |flag, desc|
        bold_flag = Rainbow(flag).bold
        padded = Util.pad_to_visible(bold_flag, cols)
        puts "  #{padded}#{desc}"
      end
    end

    def self.run_metadata(opts)
      file = opts[:kdc_file]
      return 1 unless file && File.exist?(file)

      Util.log("Parsing #{file}...")
      metadata = KDC.parse_kdc(file)

      puts metadata.to_s

      0
    end

    def self.run_convert(opts)
      file = opts[:kdc_file]
      return 1 unless file && File.exist?(file)

      output = opts[:output]
      if output&.start_with?("-")
        Util.warn(" '#{output}' looks like an option, not a filename")
        output = nil
      end
      output ||= (file && file.sub(/\.kdc$/i, ".tif"))
      no_color_correction = opts[:no_color_correction]
      remove_stuck_pixels = !opts[:no_remove_stuck_pixels]
      sharpen = opts[:sharpen]
      format = resolve_format(opts[:format], output)

      Util.log("Converting #{file} -> #{output} (#{format})")

      if opts[:verbose]
        print_conversion_options(opts, output, format)
      end

      color_lut = if no_color_correction
                    nil
                  else
                    lut_path = File.join(File.dirname(__FILE__), "..", "reference_lut.json")
                    KDC::ColorCorrection.load_lut(lut_path)
                  end

      converter = KDC::Converter.new(file, color_lut: color_lut, sharpen: sharpen, remove_stuck_pixels: remove_stuck_pixels)
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

        Util.success("Saved to #{output} - #{format.upcase}, #{bit_depth}-bit, #{Util.format_resolution(actual_width, actual_height)}, #{Util.human_size(file_size)}")
        0
      rescue => e
        Util.error("Error: #{e.message}")
        Util.error(e.backtrace.first(5).join("\n"))
        1
      end
    end

    def self.print_conversion_options(opts, output, format)
      default_output = opts[:kdc_file] && opts[:kdc_file].sub(/\.kdc$/i, ".tif")
      default_format = resolve_format(nil, opts[:kdc_file] && opts[:kdc_file].sub(/\.kdc$/i, ".tif"))

      lines = []
      lines << format_line("Output", output, opts[:output_explicit], default_output)
      lines << format_line("Format", format, opts[:format_explicit], default_format)
      lines << format_line("Color correct", opts[:no_color_correction] ? "OFF" : "ON", opts[:no_color_correction], "ON")
      lines << format_line("Stuck pixels", opts[:no_remove_stuck_pixels] ? "NOT removed" : "Removed", opts[:no_remove_stuck_pixels], "Removed")

      sharpen_info = if opts[:sharpen]
                       s = opts[:sharpen]
                       label = if s == { radius: Sharpen::AUTO_RADIUS, amount: Sharpen::AUTO_AMOUNT, threshold: Sharpen::AUTO_THRESHOLD }
                                 "auto (radius=#{Sharpen::AUTO_RADIUS}, amount=#{Sharpen::AUTO_AMOUNT}, threshold=#{Sharpen::AUTO_THRESHOLD})"
                               else
                                 "custom (radius=#{s[:radius]}, amount=#{s[:amount]}, threshold=#{s[:threshold]})"
                               end
                       [label, true]
                     else
                       ["OFF", false]
                     end
      lines << format_line("Sharpen", sharpen_info[0], sharpen_info[1], "OFF")

      puts lines.join("\n")
    end

    def self.format_line(label, value, overridden, _default)
      cols = 20
      bold_label = Rainbow(label).bold
      padded = Util.pad_to_visible(bold_label, cols)
      colored_value = overridden ? Rainbow(value).yellow : value
      "  #{padded}#{colored_value}"
    end

    def self.resolve_format(format_flag, output)
      return format_flag if format_flag && %w[tif png].include?(format_flag)

      # Auto-detect from output extension
      ext = File.extname(output).downcase.delete(".")
      return "png" if ext == "png"
      "tif"
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
