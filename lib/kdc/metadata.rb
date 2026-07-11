# frozen_string_literal: true

require_relative "util"

module KDC
  # Centralized metadata handling for KDC files.
  # Normalizes parsed KDC data into canonical forms, provides EXIF-standard output,
  # and supports human-readable display.
  #
  # Fields are named after EXIF standard names (no prefix) for standard tags,
  # or prefixed with "kdc_" for KDC-specific fields without EXIF equivalents.
  class Metadata
    # Constants mapping symbol keys to their properties.
    # Each entry: { display: "Human Readable Name", tag: 0xXXXX (nil if no EXIF equivalent), type: :ascii | :rational | :short | :symbol | :array }
    FIELD_MAP = {
      # Standard EXIF fields (no prefix)
      subfile_type: { display: "Subfile Type", tag: 0x00FD, type: :short },
      image_width: { display: "Image Width", tag: 0x0100, type: :short },
      image_length: { display: "Image Length", tag: 0x0101, type: :short },
      bits_per_sample: { display: "Bits Per Sample", tag: 0x0102, type: :array },
      compression: { display: "Compression", tag: 0x0103, type: :short },
      photometric_interpretation: { display: "Photometric Interpretation", tag: 0x0106, type: :short },
      image_description: { display: "Image Description", tag: 0x010E, type: :ascii },
      make: { display: "Make", tag: 0x010F, type: :ascii },
      model: { display: "Camera Model Name", tag: 0x0110, type: :ascii },
      strip_offsets: { display: "Strip Offsets", tag: 0x0111, type: :long },
      orientation: { display: "Orientation", tag: 0x0112, type: :short },
      samples_per_pixel: { display: "Samples Per Pixel", tag: 0x0115, type: :short },
      rows_per_strip: { display: "Rows Per Strip", tag: 0x0116, type: :long },
      strip_byte_counts: { display: "Strip Byte Counts", tag: 0x0117, type: :long },
      x_resolution: { display: "X Resolution", tag: 0x011A, type: :rational },
      y_resolution: { display: "Y Resolution", tag: 0x011B, type: :rational },
      planar_configuration: { display: "Planar Configuration", tag: 0x011C, type: :short },
      resolution_unit: { display: "Resolution Unit", tag: 0x0128, type: :short },
      software: { display: "Software", tag: 0x0131, type: :ascii },
      date_time: { display: "Modify Date", tag: 0x0132, type: :ascii },
      exposure_value: { display: "Exposure Value", tag: 0x828A, type: :rational },
      compressed_bits_per_pixel: { display: "Compressed Bits Per Pixel", tag: 0x828B, type: :short },
      sensing_method: { display: "Sensing Method", tag: 0x828C, type: :short },
      cfa_repeat_pattern_dim: { display: "CFA Repeat Pattern Dim", tag: 0x828D, type: :array },
      cfa_pattern: { display: "CFA Pattern 2", tag: 0x828E, type: :array },
      light_source: { display: "Light Source", tag: 0x828F, type: :short },
      exposure_time: { display: "Exposure Time", tag: 0x829A, type: :rational },
      f_number: { display: "F Number", tag: 0x829D, type: :rational },
      exposure_program: { display: "Exposure Program", tag: 0x8822, type: :short },
      iso: { display: "ISO", tag: 0x8827, type: :long },
      date_time_original: { display: "Date/Time Original", tag: 0x9003, type: :ascii },
      subject_distance: { display: "Subject Distance", tag: 0x920B, type: :rational },
      flash: { display: "Flash", tag: 0x9209, type: :short },
      focal_length: { display: "Focal Length", tag: 0x920A, type: :rational },
      tif_ep_standard_id: { display: "TIFF-EP Standard ID", tag: 0xA433, type: :ascii },
      copyright: { display: "Copyright", tag: 0x829B, type: :ascii },

      # KDC-specific fields (kdc_ prefix)
      kdc_camera: { display: "Camera", tag: nil, type: :symbol },
      kdc_data_offset: { display: "Data Offset", tag: nil, type: :long },
      kdc_data_size: { display: "Data Size", tag: nil, type: :long },
      kdc_white_level: { display: "White Level", tag: nil, type: :short },
      kdc_black_level: { display: "Black Level", tag: nil, type: :array },
      kdc_raw_width: { display: "Raw Width", tag: nil, type: :short },
      kdc_raw_height: { display: "Raw Height", tag: nil, type: :short },
      kdc_pixel_aspect: { display: "Pixel Aspect", tag: nil, type: :rational },
      kdc_quality: { display: "Quality", tag: nil, type: :symbol },
      kdc_cam_mul: { display: "Camera Multipliers", tag: nil, type: :array },
      kdc_battery_level: { display: "Battery Level", tag: nil, type: :ascii },
      kdc_kodak_version: { display: "Kodak Version", tag: nil, type: :ascii },
      kdc_self_timer_mode: { display: "Self Timer Mode", tag: nil, type: :short },
      kdc_image_number: { display: "Image Number", tag: nil, type: :short },
      kdc_thumbnail_tiff: { display: "Thumbnail TIFF", tag: nil, type: :binary },
      kdc_compressed_bits_per_pixel: { display: "Compressed Bits Per Pixel (KDC)", tag: nil, type: :short },
      header: { display: "TIFF Header", tag: nil, type: :object },
      ifds: { display: "IFDs", tag: nil, type: :object },
      second_ifd: { display: "Second IFD", tag: nil, type: :object }
    }.freeze

    # Flash bitfield interpretations (EXIF 0x9209)
    FLASH_VALUES = {
      0 => "No Flash",
      1 => "Fired",
      5 => "Fired",
      8 => "Auto, Fired",
      9 => "Fired, Return not detected",
      10 => "Auto, Fired, Return not detected",
      16 => "Off, Fired",
      17 => "Off, Fired, Return not detected",
      20 => "Auto, Fired",
      24 => "Auto, Fired, Return detected",
      25 => "Fired",
      29 => "Fired, Return not detected",
      32 => "Off, Fixed",
      33 => "Fired",
      37 => "Fired, Return not detected",
      40 => "Auto, Fired",
      49 => "Fired, High Rewind",
      64 => "Off, Fixed",
      65 => "Fired",
      69 => "Fired, Return not detected",
      73 => "Fired, High Rewind",
      80 => "Auto, Fired",
      112 => "Off, Fixed"
    }.freeze

    # Orientation values (EXIF 0x0112)
    ORIENTATION_VALUES = {
      1 => "Horizontal (normal)",
      2 => "Mirror horizontal",
      3 => "Rotate 180",
      4 => "Mirror vertical",
      5 => "Mirror horizontal and rotate 270 CW",
      6 => "Rotate 90 CW",
      7 => "Mirror horizontal and rotate 90 CW",
      8 => "Rotate 270 CW"
    }.freeze

    # Compression values (EXIF 0x0103)
    COMPRESSION_VALUES = {
      1 => "Uncompressed",
      6 => "JPEG (old-style)",
      7 => "JPEG"
    }.freeze

    # Exposure program values (EXIF 0x8822)
    EXPOSURE_PROGRAM_VALUES = {
      0 => "Not defined",
      1 => "Manual",
      2 => "Program normal",
      3 => "Aperture priority",
      4 => "Shutter priority",
      5 => "Creative program",
      6 => "Action program",
      7 => "Portrait mode",
      8 => "Landscape mode"
    }.freeze

    # Sensing method values (EXIF 0x828C)
    SENSING_METHOD_VALUES = {
      1 => "Not defined",
      2 => "One-chip color area",
      3 => "Two-chip color area",
      4 => "Three-chip color area",
      5 => "Color sequential area",
      7 => "Trilinear",
      9 => "Color sequential linear"
    }.freeze

    # Resolution unit values (EXIF 0x0128)
    RESOLUTION_UNIT_VALUES = {
      1 => "No unit",
      2 => "inches",
      3 => "cm"
    }.freeze

    # Light source values (EXIF 0x9208)
    LIGHT_SOURCE_VALUES = {
      0 => "Unknown",
      1 => "Daylight",
      2 => "Fluorescent",
      3 => "Tungsten (incandescent light)",
      4 => "Flash",
      9 => "Fine weather",
      10 => "Cloudy weather",
      11 => "Shade",
      12 => "Daylight fluorescent (D 5700 - 7100K)",
      13 => "Day white fluorescent (D 5000 - 7100K)",
      14 => "Cool white fluorescent (D 4000 - 5400K)",
      15 => "White fluorescent (D 3500 - 4999K)",
      17 => "Standard light A",
      18 => "Standard light B",
      19 => "Standard light C",
      20 => "D55",
      21 => "D65",
      22 => "D75",
      23 => "D50",
      24 => "ISO Studio Tungsten",
      255 => "Other"
    }.freeze

    # Exposure value formula: EV = log2(N^2 / t) where N = f-number, t = exposure time in seconds
    # Display: "EV value" or calculated from f-number and exposure time

    # Flash bitfield parsing
    FLASH_BITFIELDD = {
      0b0000_0000_0000_0000 => "No Flash",
      0b0000_0000_0000_0001 => "Fired",
      0b0000_0000_0000_0101 => "Fired",
      0b0000_0000_0000_1000 => "Auto, Fired",
      0b0000_0000_0000_1001 => "Fired, Return not detected",
      0b0000_0000_0000_1010 => "Auto, Fired, Return not detected",
      0b0000_0000_0001_0000 => "Off, Fired",
      0b0000_0000_0001_0001 => "Off, Fired, Return not detected",
      0b0000_0000_0001_0100 => "Auto, Fired",
      0b0000_0000_0001_0101 => "Auto, Fired, Return not detected",
      0b0000_0000_0010_0000 => "Off, Fixed",
      0b0000_0000_0010_0001 => "Fired",
      0b0000_0000_0010_0101 => "Fired, Return not detected",
      0b0000_0000_0011_0000 => "Auto, Fired",
      0b0000_0000_0011_0101 => "Auto, Fired, Return not detected",
      0b0000_0000_0100_0000 => "Off, Fixed",
      0b0000_0000_0100_0001 => "Fired",
      0b0000_0000_0100_0101 => "Fired, Return not detected",
      0b0000_0000_0101_0000 => "Off, Fixed",
      0b0000_0000_0101_0001 => "Fired",
      0b0000_0000_0110_0000 => "Off, Fixed"
    }.freeze

    attr_reader :fields

    def initialize(hash = {})
      @fields = {}
      hash.each do |key, value|
        set_field(key, value)
      end
    end

    # Set or update one or more values.
    # Invalid keys or values are warned and skipped (never raises).
    def set(hash)
      hash.each do |key, value|
        set_field(key, value)
      end
    end

    # Return hash of { EXIF_tag_id => canonical_value } for EXIF-mapped keys only.
    # KDC-specific keys (no EXIF tag) are excluded.
    def to_exif
      result = {}
      @fields.each do |key, value|
        field_info = FIELD_MAP[key]
        next unless field_info && field_info[:tag]

        result[field_info[:tag]] = normalize_for_exif(key, value)
      end
      result
    end

    # Return human-readable string (exiftool-style).
    # Standard EXIF fields first, KDC-specific fields appended at end.
    def to_s
      lines = []

      # Standard EXIF fields (sorted by tag ID for consistent output)
      exif_fields = FIELD_MAP.select { |_, v| v[:tag] }.sort_by { |_, v| v[:tag] }
      exif_fields.each do |key, field_info|
        value = @fields[key]
        next unless value

        display_name = field_info[:display]
        formatted_value = format_value(key, value)
        lines << "#{display_name}: #{formatted_value}"
      end

      # KDC-specific fields (in definition order)
      kdc_fields = FIELD_MAP.select { |_, v| !v[:tag] }
      kdc_fields.each do |key, field_info|
        value = @fields[key]
        next unless value

        display_name = field_info[:display]
        formatted_value = format_value(key, value)
        lines << "#{display_name}: #{formatted_value}"
      end

      lines.join("\n")
    end

    # Dynamic accessor for all fields.
    def method_missing(name, *args, **kwargs)
      if FIELD_MAP.key?(name)
        @fields[name]
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      FIELD_MAP.key?(name) || super
    end

    private

    # Set a single key/value pair with normalization and validation.
    def set_field(key, value)
      field_info = FIELD_MAP[key]
      unless field_info
        Util.warn("Unknown metadata key: #{key.inspect}. Skipping.")
        return
      end

      normalized = normalize_value(key, field_info[:type], value)
      if normalized.nil?
        Util.warn("Invalid value for #{field_info[:display]} (#{key.inspect}): #{value.inspect}. Skipping.")
        return
      end

      @fields[key] = normalized
    end

    # Normalize a value to its canonical form based on the field type.
    def normalize_value(key, type, value)
      case type
      when :ascii
        normalize_ascii(key, value)
      when :rational
        normalize_rational(key, value)
      when :short
        normalize_short(key, value)
      when :long
        normalize_integer(key, value)
      when :symbol
        normalize_symbol(key, value)
      when :array
        normalize_array(key, value)
      when :binary
        value # Binary data stored as-is
      when :object
        value # Objects (header, ifds, second_ifd) stored as-is
      else
        value
      end
    end

    # Normalize ASCII values (Strings stored as-is).
    def normalize_ascii(key, value)
      case key
      when :make, :model, :software, :date_time, :date_time_original, :image_description,
           :tif_ep_standard_id, :copyright, :kdc_battery_level, :kdc_kodak_version
        value.is_a?(String) ? value : value.to_s
      else
        value.is_a?(String) ? value : value.to_s
      end
    end

    # Normalize Rational values (parse strings like "1/223" or "2.5" to Rational).
    def normalize_rational(key, value)
      case value
      when Rational
        value
      when Integer
        Rational(value, 1)
      when Float
        Rational(value).reduce
      when String
        parse_rational_string(value)
      else
        nil
      end
    end

    # Parse a string to Rational (e.g., "1/223" → Rational(1, 223), "2.5" → Rational(5, 2)).
    def parse_rational_string(str)
      str = str.strip
      if str.include?("/")
        parts = str.split("/").map(&:to_i)
        return nil unless parts.length == 2 && parts[1] != 0

        Rational(parts[0], parts[1])
      elsif str.include?(".")
        Rational(str.to_f)
      elsif str.match?(/\A\d+\z/)
        Rational(str.to_i, 1)
      else
        nil
      end
    end

    # Normalize Short values (16-bit integers).
    def normalize_short(key, value)
      case key
      when :flash
        normalize_flash(value)
      when :orientation
        normalize_orientation(value)
      when :compression
        normalize_compression(value)
      when :exposure_program
        normalize_exposure_program(value)
      when :sensing_method
        normalize_sensing_method(value)
      when :resolution_unit
        normalize_resolution_unit(value)
      when :light_source
        normalize_light_source(value)
      else
        normalize_integer(key, value)
      end
    end

    # Normalize integer values.
    def normalize_integer(key, value)
      case value
      when Integer
        value
      when String
        value.match?(/\A\d+\z/) ? value.to_i : nil
      else
        nil
      end
    end

    # Normalize Symbol values.
    def normalize_symbol(key, value)
      case value
      when Symbol
        value
      when String
        value.to_sym
      else
        nil
      end
    end

    # Normalize Array values.
    def normalize_array(key, value)
      case value
      when Array
        value.map(&:to_i)
      when String
        value.split(/\s+/).map(&:to_i)
      else
        nil
      end
    end

    # Normalize Flash value to integer bitfield.
    def normalize_flash(value)
      case value
      when Integer
        value
      when String
        parse_flash_string(value)
      else
        nil
      end
    end

    # Parse flash string (e.g., "Auto, Fired, Return detected") to integer bitfield.
    def parse_flash_string(str)
      str = str.strip.downcase
      FLASH_BITFIELDD.each do |bitfield, description|
        return bitfield if description.downcase == str
      end
      nil
    end

    # Normalize Orientation value to integer.
    def normalize_orientation(value)
      case value
      when Integer
        value
      when String
        ORIENTATION_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize Compression value to integer.
    def normalize_compression(value)
      case value
      when Integer
        value
      when String
        COMPRESSION_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize Exposure Program value to integer.
    def normalize_exposure_program(value)
      case value
      when Integer
        value
      when String
        EXPOSURE_PROGRAM_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize Sensing Method value to integer.
    def normalize_sensing_method(value)
      case value
      when Integer
        value
      when String
        SENSING_METHOD_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize Resolution Unit value to integer.
    def normalize_resolution_unit(value)
      case value
      when Integer
        value
      when String
        RESOLUTION_UNIT_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize Light Source value to integer.
    def normalize_light_source(value)
      case value
      when Integer
        value
      when String
        LIGHT_SOURCE_VALUES.each do |id, name|
          return id if name.downcase == value.downcase
        end
        nil
      else
        nil
      end
    end

    # Normalize a value for EXIF output (convert to EXIF-compatible format).
    def normalize_for_exif(key, value)
      field_info = FIELD_MAP[key]
      return value unless field_info

      case field_info[:type]
      when :ascii
        value
      when :rational
        value.is_a?(Rational) ? value : value.to_r
      when :short, :long
        value.is_a?(Integer) ? value : value.to_i
      when :array
        value.is_a?(Array) ? value : value.to_a
      else
        value
      end
    end

    # Format a value for human-readable display.
    def format_value(key, value)
      field_info = FIELD_MAP[key]
      return value.inspect unless field_info

      case field_info[:type]
      when :ascii
        value
      when :rational
        format_rational(value)
      when :short
        format_short(key, value)
      when :long
        value.to_s
      when :symbol
        value.to_s
      when :array
        value.inspect
      when :binary
        "(Binary data #{value.bytesize} bytes)"
      when :object
        value.nil? ? "nil" : value.class.to_s
      else
        value.inspect
      end
    end

    # Format a Rational value for display (e.g., "1/223" or "2.5").
    def format_rational(value)
      return "0" if value.zero?

      if value.denominator == 1
        value.numerator.to_s
      else
        "#{value.numerator}/#{value.denominator}"
      end
    end

    # Format a Short value for display (e.g., "Auto, Fired, Return detected" for flash).
    def format_short(key, value)
      case key
      when :flash
        FLASH_VALUES[value] || value.to_s
      when :orientation
        ORIENTATION_VALUES[value] || value.to_s
      when :compression
        COMPRESSION_VALUES[value] || value.to_s
      when :exposure_program
        EXPOSURE_PROGRAM_VALUES[value] || value.to_s
      when :sensing_method
        SENSING_METHOD_VALUES[value] || value.to_s
      when :resolution_unit
        RESOLUTION_UNIT_VALUES[value] || value.to_s
      when :light_source
        LIGHT_SOURCE_VALUES[value] || value.to_s
      else
        value.to_s
      end
    end
  end
end
