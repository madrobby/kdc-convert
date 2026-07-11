# frozen_string_literal: true

module KDC
  # Standard EXIF tag IDs (symbol key -> tag ID).
  # Kodak-specific tags (WhiteBalance, LightSource, MakerNote) are accessible
  # but excluded from serialization whitelist.
  TAG_ID = {
    make:               0x010F,
    model:              0x0110,
    exposure_time:      0x829A,
    f_number:           0x829D,
    iso:                0x8827,
    date_time_original: 0x9003,
    flash:              0x9209,
    focal_length:       0x920A,
    exposure_program:   0x8822,
    date_time:          0x0132,
    software:           0x0131,
    white_balance:      0x8298,
    light_source:       0x828F,
    maker_note:         0x9216,
  }.freeze

  # Reverse lookup: tag ID -> symbol key (for raw data section of to_s).
  TAG_SYMBOL = TAG_ID.invert.freeze

  # Whitelist of tags eligible for TIFF serialization (standard EXIF only).
  # Kodak-specific and MakerNote are intentionally excluded.
  WHITELIST = %i[
    make
    model
    exposure_time
    f_number
    iso
    date_time_original
    flash
    focal_length
    exposure_program
    date_time
    software
  ].freeze

  # Flash tag bitfield: bit 0 = flash fired, bit 8 = return status.
  FLASH_BITFIRED = 0x0020

  # Human-readable labels for normalized tags (for to_s output).
  LABELS = {
    make:               "Make",
    model:              "Model",
    exposure_time:      "ExposureTime",
    f_number:           "FNumber",
    iso:                "ISO",
    date_time_original: "DateTimeOriginal",
    flash:              "Flash",
    focal_length:       "FocalLength",
    exposure_program:   "ExposureProgram",
    date_time:          "DateTime",
    software:           "Software",
    white_balance:      "WhiteBalance",
    light_source:       "LightSource",
    maker_note:         "MakerNote",
  }.freeze

  # Symbol lookup tables for enum tags.
  WHITE_BALANCE_NAMES = {
    0 => :unknown,
    1 => :daylight,
    2 => :fluorescent,
    3 => :tungsten,
    4 => :flash,
    9 => :fine_weather,
    10 => :cloudy,
    11 => :shade,
    14 => :fluorescent_low,
    255 => :manual,
  }.freeze

  LIGHT_SOURCE_NAMES = {
    0 => :unknown,
    1 => :daylight,
    2 => :fluorescent,
    3 => :tungsten,
    4 => :flash,
    9 => :fine_weather,
    10 => :cloudy,
    11 => :shade,
    14 => :fluorescent_low,
    17 => :hd_5500k,
    20 => :d75,
    21 => :d50,
    22 => :pentax_inkjet,
  }.freeze

  EXPOSURE_PROGRAM_NAMES = {
    0 => :not_defined,
    1 => :manual,
    2 => :normal_program,
    3 => :aperture_priority,
    4 => :shutter_priority,
    5 => :creative,
    6 => :action,
    7 => :portrait_mode,
    8 => :landscape_mode,
  }.freeze

  # Normalized EXIF data from a KDC file.
  #
  # Construction:
  #   exif = KDC::Exif.new(make: "Eastman Kodak", model: "DC120", ...)
  #
  # All accessors return nil for missing/invalid tags.
  class Exif
    # Build an Exif from a symbol-keyed hash.
    #
    # @param data [Hash{Symbol => Object}] symbol-keyed hash of EXIF tag values.
    #   Keys may be any recognized symbol (whitelist or not). Unknown keys are
    #   stored in the raw data section for fallback display.
    # @param hash [Hash] defaults to {}
    def initialize(data = {})
      @data = data.dup
      @raw_data = {}

      data.each do |key, value|
        if KDC::TAG_ID.key?(key)
          instance_variable_set("@#{key}", normalize_value(key, value))
        else
          @raw_data[key] = value
        end
      end
    end

    # --- Normalized (typed) accessors ---

    def make
      @make
    end

    def model
      @model
    end

    # @return [Rational, nil]
    def exposure_time
      @exposure_time
    end

    # @return [Float, nil]
    def f_number
      @f_number
    end

    # @return [Integer, nil]
    def iso
      @iso
    end

    # @return [true, false, nil]
    def flash_fired?
      return nil if @flash.nil?
      if @flash.is_a?(Integer)
        !!(@flash & KDC::FLASH_BITFIRED).nonzero?
      else
        !!@flash
      end
    end

    # Convenience: was flash fired at all? (alias for flash_fired?)
    def flash
      flash_fired?
    end

    # @return [Integer, nil] (equivalent 35mm focal length)
    def focal_length
      @focal_length
    end

    # @return [String, nil] e.g. "2026:07:11 10:30:00"
    def date_time_original
      @date_time_original
    end

    # @return [Symbol, nil]
    def white_balance
      @white_balance
    end

    # @return [Symbol, nil]
    def light_source
      @light_source
    end

    # @return [Symbol, nil]
    def exposure_program
      @exposure_program
    end

    # @return [String, nil] e.g. "2026:07:11 10:30:00"
    def date_time
      @date_time
    end

    # @return [String, nil]
    def software
      @software
    end

    # Raw (unnormalized) data for tags not in the normalized set, or for tags
    # whose values couldn't be normalized. Used by `to_s` fallback section.
    # @return [Hash{Symbol => Object}]
    def raw_data
      @raw_data
    end

    # --- Output ---

    # Human-readable formatted string.
    #
    # @return [String]
    def to_s
      return "(no EXIF data)" if @data.empty? && @raw_data.empty?

      lines = ["=== EXIF Metadata ==="]
      KDC::WHITELIST.each do |tag|
        value = public_send(tag)
        next if value.nil?
        lines << "  #{format_tag_label(tag)}: #{format_value(tag, value)}"
      end

      unless @raw_data.empty?
        lines << ""
        lines << "  --- Unnormalized data ---"
        @raw_data.each do |key, value|
          lines << "  #{format_tag_label(key)}: #{value.inspect}"
        end
      end

      lines.join("\n")
    end

    # Terse shot summary for verbose conversion output.
    #
    # Combines focal length, f-number, and exposure time into a compact string.
    # Missing values are omitted.
    #
    # @return [String] e.g. "35mm f/2.8 0.25s" or ""
    def to_shot_summary
      parts = []

      if @focal_length && @focal_length > 0
        parts << "#{@focal_length}mm"
      end

      if @f_number && @f_number > 0
        parts << "\u0192/#{format_float(@f_number)}"
      end

      if (formatted = format_exposure_time(@exposure_time))
        parts << formatted
      end

      parts.join(" ")
    end

    # Array of TIFF IFD entry arrays for whitelist-eligible tags.
    #
    # Each entry is [tag_id, type, count, value] suitable for passing to
    # `TIFFWriter#add_exif_entry`.
    #
    # @return [Array<Array>]
    def to_tiff_entries
      entries = []
      KDC::WHITELIST.each do |tag|
        value = public_send(tag)
        next if value.nil?
        entry = build_tiff_entry(tag, value)
        entries << entry if entry
      end
      entries
    end

    # Write all serializable EXIF entries to a TIFF writer.
    #
    # @param writer [TIFFWriter]
    def serialize(writer)
      to_tiff_entries.each { |entry| writer.add_exif_entry(*entry) }
    end

    private

    # Normalize a raw value based on the tag's expected type.
    def normalize_value(tag, value)
      case tag
      when :make, :model, :date_time_original, :date_time, :software
        value.is_a?(String) ? value : value.to_s
      when :exposure_time
        to_rational(value)
      when :f_number
        to_float(value)
      when :iso, :focal_length
        to_int(value)
      when :flash
        to_bool(value)
      when :white_balance, :light_source, :exposure_program
        to_enum(tag, value)
      when :maker_note
        value
      else
        value
      end
    rescue StandardError
      nil
    end

    # --- Type converters ---

    def to_rational(value)
      return nil if value.nil?
      case value
      when Rational
        value
      when Integer
        value > 0 ? Rational(1, value) : nil
      when Float
        value > 0 ? Rational(value.to_r) : nil
      when String
        if value.include?("/")
          num, denom = value.split("/", 2).map(&:to_i)
          denom > 0 ? Rational(num, denom) : nil
        else
          v = value.to_f
          v > 0 ? Rational(v.to_r) : nil
        end
      else
        nil
      end
    end

    def to_float(value)
      return nil if value.nil?
      case value
      when Float
        value
      when Integer
        value > 0 ? value.to_f : nil
      when String
        v = Float(value) rescue nil
        v && v > 0 ? v : nil
      else
        nil
      end
    end

    def to_int(value)
      return nil if value.nil?
      case value
      when Integer
        value > 0 ? value : nil
      when String
        value.match?(/\A\d+\z/) ? value.to_i : nil
      else
        nil
      end
    end

    def to_bool(value)
      return nil if value.nil?
      if value.is_a?(Integer)
        !!((value & KDC::FLASH_BITFIRED).nonzero?)
      else
        !!value
      end
    end

    def to_enum(tag, value)
      return nil if value.nil?
      case value
      when Integer
        case tag
        when :white_balance then KDC::WHITE_BALANCE_NAMES[value]
        when :light_source  then KDC::LIGHT_SOURCE_NAMES[value]
        when :exposure_program then KDC::EXPOSURE_PROGRAM_NAMES[value]
        end
      when Symbol
        case tag
        when :white_balance then KDC::WHITE_BALANCE_NAMES.invert[value]
        when :light_source  then KDC::LIGHT_SOURCE_NAMES.invert[value]
        when :exposure_program then KDC::EXPOSURE_PROGRAM_NAMES.invert[value]
        end
      else
        nil
      end
    end

    # --- TIFF serialization helpers ---

    def build_tiff_entry(tag, value)
      tag_id = KDC::TAG_ID[tag]
      case tag
      when :make, :model, :date_time_original, :date_time, :software
        str = value.to_s
        return nil if str.empty?
        [tag_id, KDC::TIFF_TYPE_ASCII, str.bytesize + 1, str]
      when :exposure_time
        r = value
        [tag_id, KDC::TIFF_TYPE_RATIONAL, 1, [r.numerator, r.denominator]]
      when :f_number
        # Pack as single 32-bit IEEE 754 float
        packed = [value].pack("G")
        [tag_id, KDC::TIFF_TYPE_LONG, 1, packed.unpack1("V")]
      when :iso, :focal_length
        [tag_id, KDC::TIFF_TYPE_SHORT, 1, value]
      when :flash
        # Encode as bitfield: 0 = no flash, 0x0020 = fired
        ivalue = value ? KDC::FLASH_BITFIRED : 0
        [tag_id, KDC::TIFF_TYPE_SHORT, 1, ivalue]
      when :white_balance, :light_source, :exposure_program
        inv = inverse_enum(tag, value)
        inv.nil? ? nil : [tag_id, KDC::TIFF_TYPE_SHORT, 1, inv]
      else
        nil
      end
    end

    def inverse_enum(tag, value)
      case value
      when Integer
        # Already an integer, just validate it's a known value
        case tag
        when :white_balance then KDC::WHITE_BALANCE_NAMES[value] ? value : nil
        when :light_source  then KDC::LIGHT_SOURCE_NAMES[value] ? value : nil
        when :exposure_program then KDC::EXPOSURE_PROGRAM_NAMES[value] ? value : nil
        else nil
        end
      when Symbol
        case tag
        when :white_balance then KDC::WHITE_BALANCE_NAMES.invert[value]
        when :light_source  then KDC::LIGHT_SOURCE_NAMES.invert[value]
        when :exposure_program then KDC::EXPOSURE_PROGRAM_NAMES.invert[value]
        else nil
        end
      else
        nil
      end
    end

    # --- Display helpers ---

    def format_tag_label(tag)
      KDC::LABELS[tag] || tag.to_s
    end

    def format_value(tag, value)
      case tag
      when :make, :model
        value
      when :exposure_time
        format_exposure_time(value)
      when :f_number
        "\u0192/#{format_float(value)}"
      when :flash
        value ? "fired" : "not fired"
      when :iso
        "#{value}"
      when :focal_length
        "#{value}mm"
      when :white_balance, :light_source, :exposure_program
        value.to_s
      when :date_time_original, :date_time
        value
      when :software
        value
      else
        value.inspect
      end
    end

    def format_float(v)
      if v == v.to_i
        v.to_i.to_s
      else
        "%.2g" % v
      end
    end

    def format_exposure_time(time)
      seconds = time.to_f
      return nil if seconds <= 0

      if seconds >= 1
        "%.1f" % seconds
      else
        formatted = "%.3f" % seconds
        formatted = formatted.sub(/0+\z/, "")
        "#{formatted}s"
      end
    end
  end
end
