# frozen_string_literal: true

require "optparse"
require_relative "kdc/kdc_parser"
require_relative "kdc/dc120"
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

      mode = opts[:metadata] ? :metadata : :convert
      run_mode(mode, opts)
    end

    def self.parse_options(args)
        opts = {
          verbose: false,
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
          force: false,
          depth: 8,
          glitch: nil,
        }

      parser = OptionParser.new do |o|
        o.banner = "Usage: kdc [options] <file.kdc>"

        o.on("-m", "--metadata", "Show KDC metadata") { opts[:metadata] = true }
        o.on("-o", "--output PATH", "Output file path") { |v| opts[:output] = v; opts[:output_explicit] = true }
        o.on("-f", "--format {tif|png|dng}", "Output format: tif, png, or dng (default: auto-detect from -o extension)") do |v|
          opts[:format_explicit] = true
          if %w[tif png dng].include?(v.downcase)
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
        o.on("--glitch[=N]", "Apply PNG glitch effect (0-100, default 50)\n" \
                              "Only applies to PNG output") do |v|
          val = v ? v.to_i : 50
          val = [[val, 0].max, 100].min
          opts[:glitch] = val
        end
        o.on("-F", "--force", "Overwrite output file if it exists") { opts[:force] = true }
        o.on("--depth {8|16}", "Output bit depth for TIFF (default: 8)") { |v| opts[:depth] = v.to_i }
        o.on("-h", "--help", "Show help") { opts[:help] = true }
      end

      remaining = parser.parse(args)
      opts[:kdc_file] = remaining.first
      opts
    end

    def self.run_mode(mode, opts)
      Util.verbose = opts[:verbose]
      Rainbow.enabled = !opts[:no_color]
      warn_conversion_flags_if_metadata(opts) if mode == :metadata
      case mode
      when :metadata then run_metadata(opts)
      when :convert  then run_convert(opts)
      end
    end

    private

    def self.warn_conversion_flags_if_metadata(opts)
      conversion_flags = {
        output:                "-o / --output",
        format:                "-f / --format",
        sharpen:               "--sharpen",
        no_color_correction:   "--no-color-correction",
        no_remove_stuck_pixels: "--no-remove-stuck-pixels",
        glitch:                "--glitch",
      }
      conversion_flags.each do |key, flag|
        if opts[key]
          Util.warn("#{flag} only applies to conversion, ignoring")
        end
      end
    end

    def self.print_usage
      puts "kdc - Pure Ruby KDC file parser and converter (LibRaw port)"
      puts
      puts "Usage:"
      puts "  kdc [options] <file.kdc>    Convert KDC to TIFF/PNG/DNG (default: TIFF)"

      cols = 60
      opts = [
        ["-m, --metadata", "Show KDC metadata"],
        ["-o, --output PATH", "Output file path"],
        ["-f, --format {tif|png|dng}", "Output format: tif, png, or dng (default: auto-detect from -o extension)"],
        ["-v, --verbose", "Show step-by-step progress with timings"],
        ["--no-color", "Disable colored output"],
        ["--no-color-correction", "Skip color correction step"],
        ["--no-remove-stuck-pixels", "Skip stuck pixel removal after JPEG decode"],
        ["--sharpen[=r,a,t]", "Apply unsharp mask sharpening (opt-in)\n" \
                               "    Bare flag or =auto for medium strength\n" \
                               "    =r,a,t for custom radius,amount,threshold"],
        ["--glitch[=N]", "Apply PNG glitch effect (0-100, default 50)\n" \
                          "    Only applies to PNG output"],
        ["--depth {8|16}", "Output bit depth for TIFF (default: 8)"],
        ["-F, --force", "Overwrite output file if it exists"],
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
      return 1 unless file && validate_input_file(file)

      Util.log("Parsing #{file}...")
      metadata = KDC.parse_kdc(file)

      puts metadata.to_s

      0
    end

    def self.run_convert(opts)
      file = opts[:kdc_file]
      return 1 unless file && validate_input_file(file)

      output = opts[:output]
      if output&.start_with?("-")
        Util.warn(" '#{output}' looks like an option, not a filename")
        output = nil
      end
      output ||= (file && file.sub(/\.kdc$/i, ".tif"))

      # Check if output file exists and --force not given
      if File.exist?(output) && !opts[:force]
        Util.error("Error: Output file '#{output}' already exists. Use --force to overwrite.")
        return 1
      end

      # Warn if --force is used and file exists (will be overwritten)
      if File.exist?(output) && opts[:force]
        Util.warn("Warning: Overwriting existing file '#{output}'")
      end

      format = resolve_format(opts[:format], output)

      # Warn about ignored options for DNG format
      if format == "dng"
        Util.warn("--sharpen has no effect with DNG output") if opts[:sharpen]
        Util.warn("--no-color-correction has no effect with DNG output") if opts[:no_color_correction]
        Util.warn("--depth has no effect with DNG output (always 16-bit)") if opts[:depth] && opts[:depth] != 8
        Util.warn("--glitch has no effect with DNG output") if opts[:glitch]
      end

      if opts[:glitch] && format != "png"
        Util.warn("--glitch has no effect with #{format.upcase} output (PNG only)")
      end

      no_color_correction = opts[:no_color_correction]
      remove_stuck_pixels = !opts[:no_remove_stuck_pixels]
      sharpen = opts[:sharpen]

      Util.log("Converting #{file} -> #{output} (#{format})")

      if opts[:verbose]
        print_conversion_options(opts, output, format)
      end

      color_lut = if format == "dng" || no_color_correction
                    nil
                  else
                    lut_path = File.join(File.dirname(__FILE__), "..", "reference_lut.json")
                    KDC::ColorCorrection.load_lut(lut_path)
                  end

      converter = KDC::Converter.new(file, color_lut: color_lut, sharpen: sharpen, remove_stuck_pixels: remove_stuck_pixels, glitch: opts[:glitch])
      begin
        case format
        when "dng"
          converter.convert_to_dng(output)
          bit_depth = 16
        when "png"
          converter.convert_to_png(output)
          bit_depth = 8
        else
          depth = opts[:depth] == 16 ? 16 : 8
          converter.convert_to_tiff(output, bit_depth: depth)
          bit_depth = depth
        end

        file_size = File.size(output)
        img = format == "dng" ? converter.raw_image : converter.demosaiced_image
        actual_width = img[0].length
        actual_height = img.length

        fmt_label = case format
                    when "dng" then "DNG"
                    when "png" then "PNG"
                    else "TIFF"
                    end
        Util.success("Saved to #{output} - #{fmt_label}, #{bit_depth}-bit, #{Util.format_resolution(actual_width, actual_height)}, #{Util.human_size(file_size)}")
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
        fmt_desc = case format
                 when "png" then "24-bit PNG"
                 when "dng" then "16-bit DNG (raw Bayer)"
                 else "#{opts[:depth] || 8}-bit RGB TIFF (big endian)"
                 end
      lines << format_line("Format", fmt_desc, opts[:format_explicit], default_format)

      if format == "dng"
        lines << format_line("Stuck pixels", opts[:no_remove_stuck_pixels] ? "NOT removed" : "Removed", opts[:no_remove_stuck_pixels], "Removed")
      else
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

        glitch_info = if opts[:glitch]
                        ["#{opts[:glitch]}%", true]
                      else
                        ["OFF", false]
                      end
        lines << format_line("Glitch", glitch_info[0], glitch_info[1], "OFF") if format == "png"
      end

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
      return format_flag if format_flag && %w[tif png dng].include?(format_flag)

      # Auto-detect from output extension
      ext = File.extname(output).downcase.delete(".")
      return "png" if ext == "png"
      return "dng" if ext == "dng"
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

    def self.validate_input_file(file)
      if file.empty?
        Util.error("Error: No input file specified")
        return false
      end
      unless File.exist?(file)
        Util.error("Error: File not found: #{file}")
        return false
      end
      unless File.file?(file)
        Util.error("Error: Not a regular file: #{file}")
        return false
      end
      unless File.readable?(file)
        Util.error("Error: Cannot read file (permission denied): #{file}")
        return false
      end
      true
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit KDC::App.run(ARGV)
end
