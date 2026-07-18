# frozen_string_literal: true

module KDC
  # DNG writer for Kodak DC120/DC50 raw Bayer data.
  #
  # Follows dnglab's structure for maximum compatibility:
  #   - Little-endian ("II") byte order
  #   - Root IFD (IFD0): DNG metadata + SubIFDs pointer + EXIF pointer
  #   - SubIFD: raw Bayer image data (CFA, BlackLevel, etc.)
  #   - EXIF IFD: camera exposure metadata
  #   - Layout: header → raw pixels → SubIFD → EXIF → root IFD
  #
  class DNGWriter
    TAG_NEW_SUBFILE_TYPE     = 0x00FE
    TAG_IMAGE_WIDTH          = 0x0100
    TAG_IMAGE_LENGTH         = 0x0101
    TAG_BITS_PER_SAMPLE      = 0x0102
    TAG_COMPRESSION          = 0x0103
    TAG_PHOTOMETRIC_INTERP   = 0x0106
    TAG_MAKE                 = 0x010F
    TAG_MODEL                = 0x0110
    TAG_STRIP_OFFSETS        = 0x0111
    TAG_SAMPLES_PER_PIXEL    = 0x0115
    TAG_ROWS_PER_STRIP       = 0x0116
    TAG_STRIP_BYTE_COUNTS    = 0x0117
    TAG_PLANAR_CONFIGURATION = 0x011C
    TAG_SAMPLE_FORMAT        = 0x0153
    TAG_SUB_IFDS             = 0x014A

    TAG_EXIF_IFD_POINTER       = 0x8769

    TAG_CFA_REPEAT_PATTERN_DIM = 0x828D
    TAG_CFAPATTERN             = 0x828E

    TAG_DNG_VERSION            = 0xC612
    TAG_DNG_BACKWARD_VERSION   = 0xC613
    TAG_UNIQUE_CAMERA_MODEL    = 0xC614
    TAG_COLOR_MATRIX1          = 0xC621
    TAG_AS_SHOT_NEUTRAL        = 0xC628
    TAG_BLACK_LEVEL_REPEAT_DIM = 0xC619
    TAG_BLACK_LEVEL            = 0xC61A
    TAG_WHITE_LEVEL            = 0xC61D
    TAG_DEFAULT_SCALE          = 0xC61E
    TAG_BEST_QUALITY_SCALE     = 0xC65C
    TAG_CALIBRATION_ILLUMINANT1 = 0xC65A
    TAG_CFA_PLANE_COLOR        = 0xC616
    TAG_CFA_LAYOUT             = 0xC617
    TAG_ACTIVE_AREA            = 0xC68D
    TAG_DEFAULT_CROP_ORIGIN    = 0xC61F
    TAG_DEFAULT_CROP_SIZE      = 0xC620

    TAG_EXPOSURE_TIME     = 0x829A
    TAG_FNUMBER           = 0x829D
    TAG_ISO_SPEED         = 0x8827
    TAG_DATETIME_ORIGINAL = 0x9003
    TAG_FOCAL_LENGTH      = 0x920A

    TYPE_BYTE     = 1
    TYPE_ASCII    = 2
    TYPE_SHORT    = 3
    TYPE_LONG     = 4
    TYPE_RATIONAL = 5
    TYPE_SRATIONAL = 10

    def initialize(width, height, camera_data, white_level: 65535,
                   as_shot_neutral: nil, make: "Kodak", model: "Unknown",
                   thumbnail: nil)
      @width = width
      @height = height
      @camera_data = camera_data
      @white_level = white_level
      @as_shot_neutral = as_shot_neutral
      @make = make
      @model = model
      @thumbnail = thumbnail
      @raw_data = nil

      @root_entries = []
      @sub_entries  = []
      @exif_entries = []
    end

    def set_raw_data(data)
      @raw_data = data
    end

    def set_exif(exposure_time: nil, f_number: nil, iso: nil,
                 focal_length: nil, date_time_original: nil)
      @exif_exposure_time = exposure_time
      @exif_f_number = f_number
      @exif_iso = iso
      @exif_focal_length = focal_length
      @exif_date_time_original = date_time_original
    end

    def write(output_path)
      build_exif_ifd_entries
      build_root_ifd_entries
      build_sub_ifd_entries

      header_size = 8

      # Step 1: Compute all sizes and offsets (no binary built yet)
      image_offset = header_size
      image_size = @height * @width * 2 # 16-bit LE pixels

      subifd_offset = align4(image_offset + image_size)
      subifd_ifd_size = ifd_binary_size(@sub_entries)
      subifd_ext_size = external_data_size(@sub_entries)

      exif_offset = nil
      exif_ifd_size = 0
      exif_ext_size = 0
      if @exif_entries.any?
        exif_offset = align4(subifd_offset + subifd_ifd_size + subifd_ext_size)
        exif_ifd_size = ifd_binary_size(@exif_entries)
        exif_ext_size = external_data_size(@exif_entries)
      end

      root_base = if exif_offset
                     align4(exif_offset + exif_ifd_size + exif_ext_size)
                   else
                     align4(subifd_offset + subifd_ifd_size + subifd_ext_size)
                   end
      root_ifd_size = ifd_binary_size(@root_entries)
      root_ext_size = external_data_size(@root_entries)
      total_size = root_base + root_ifd_size + root_ext_size

      # Step 2: Set external data offsets on entries (so pack_inline_or_offset works)
      set_external_offsets(@sub_entries, subifd_offset + subifd_ifd_size)
      set_external_offsets(@exif_entries, exif_offset.to_i + exif_ifd_size) if exif_offset
      set_external_offsets(@root_entries, root_base + root_ifd_size)

      # Step 3: Update root IFD pointers and SubIFD strip offset
      update_root_sub_ifds(subifd_offset)
      update_root_exif_pointer(exif_offset) if exif_offset
      update_sub_strip_offsets(image_offset)

      # Step 4: Build binaries
      image_data = build_image_data
      subifd_data = build_ifd_binary(@sub_entries, 0)
      subifd_external = build_external_data(@sub_entries)

      if exif_offset
        exif_data = build_ifd_binary(@exif_entries, 0)
        exif_external = build_external_data(@exif_entries)
      end

      root_data = build_ifd_binary(@root_entries, 0)
      root_external = build_external_data(@root_entries)

      # Step 5: Assemble file: header → raw pixels → padding → SubIFD → EXIF → root IFD
      output = String.new(encoding: Encoding::BINARY, capacity: total_size)
      output << tiff_header(root_base)
      output << image_data
      output << "\0" * (subifd_offset - image_offset - image_size)
      output << subifd_data
      output << subifd_external
      if exif_offset
        output << "\0" * (exif_offset - subifd_offset - subifd_ifd_size - subifd_ext_size)
        output << exif_data
        output << exif_external
      end
      output << "\0" * (root_base - output.bytesize)
      output << root_data
      output << root_external

      File.write(output_path, output)
    end

    private

    # ── IFD0 (root): DNG metadata ──

    def build_root_ifd_entries
      add_root(TAG_DNG_VERSION,          TYPE_BYTE,  4, [1, 4, 0, 0])
      add_root(TAG_DNG_BACKWARD_VERSION, TYPE_BYTE,  4, [1, 1, 0, 0])
      add_root(TAG_MAKE,                 TYPE_ASCII, @make.bytesize + 1, @make)
      add_root(TAG_MODEL,                TYPE_ASCII, @model.bytesize + 1, @model)
      add_root(TAG_UNIQUE_CAMERA_MODEL,  TYPE_ASCII, @model.bytesize + 1, @model)

      if @camera_data && @camera_data[:color_matrix1]
        srats = @camera_data[:color_matrix1].map { |v| [(v * 10000).round, 10000] }
        add_root(TAG_COLOR_MATRIX1, TYPE_SRATIONAL, srats.length, srats)
      end

      add_root(TAG_CALIBRATION_ILLUMINANT1, TYPE_SHORT, 1,
               @camera_data&.dig(:calibration_illuminant1) || 21) if @camera_data

      if @as_shot_neutral
        rats = @as_shot_neutral.map { |v| to_rational_pair(v) }
        add_root(TAG_AS_SHOT_NEUTRAL, TYPE_RATIONAL, rats.length, rats)
      end

      add_root(TAG_SUB_IFDS, TYPE_LONG, 1, 0) # placeholder

      add_root(TAG_EXIF_IFD_POINTER, TYPE_LONG, 1, 0) if @exif_entries.any?
    end

    # ── SubIFD: raw Bayer image ──

    def build_sub_ifd_entries
      add_sub(TAG_NEW_SUBFILE_TYPE,     TYPE_LONG,  1, 0)
      add_sub(TAG_IMAGE_WIDTH,          TYPE_LONG,  1, @width)
      add_sub(TAG_IMAGE_LENGTH,         TYPE_LONG,  1, @height)
      add_sub(TAG_COMPRESSION,          TYPE_SHORT, 1, 1)
      add_sub(TAG_PHOTOMETRIC_INTERP,   TYPE_SHORT, 1, 32803) # CFA
      add_sub(TAG_SAMPLES_PER_PIXEL,    TYPE_SHORT, 1, 1)
      add_sub(TAG_BITS_PER_SAMPLE,      TYPE_SHORT, 1, 16)
      add_sub(TAG_SAMPLE_FORMAT,        TYPE_SHORT, 1, 1)
      add_sub(TAG_PLANAR_CONFIGURATION, TYPE_SHORT, 1, 1)

      if @camera_data
        cfa_dim = @camera_data[:cfa_repeat_pattern_dim] || [2, 2]
        add_sub(TAG_CFA_REPEAT_PATTERN_DIM, TYPE_SHORT, 2, cfa_dim)
        cfa = @camera_data[:cfa_pattern] || [1, 0, 2, 1]
        add_sub(TAG_CFAPATTERN, TYPE_BYTE, cfa.length, cfa)
        add_sub(TAG_CFA_PLANE_COLOR, TYPE_BYTE, 3, @camera_data[:cfa_plane_color] || [0, 1, 2])
        add_sub(TAG_CFA_LAYOUT, TYPE_SHORT, 1, 1)
      end

      bl = @camera_data&.dig(:black_level) || 0
      add_sub(TAG_BLACK_LEVEL_REPEAT_DIM, TYPE_SHORT, 2, [1, 1])
      add_sub(TAG_BLACK_LEVEL, TYPE_SHORT, 1, bl)
      add_sub(TAG_WHITE_LEVEL, TYPE_SHORT, 1, @white_level)

      add_sub(TAG_DEFAULT_SCALE, TYPE_RATIONAL, 2, [[80, 52], [1, 1]])
      add_sub(TAG_BEST_QUALITY_SCALE, TYPE_RATIONAL, 1, [[1, 1]])
      add_sub(TAG_DEFAULT_CROP_ORIGIN, TYPE_LONG, 2, [8, 8])
      add_sub(TAG_DEFAULT_CROP_SIZE, TYPE_LONG, 2, [@width - 16, @height - 16])
      add_sub(TAG_ACTIVE_AREA, TYPE_LONG, 4, [0, 0, @height, @width])

      strip_bytes = @width * @height * 2
      add_sub(TAG_STRIP_OFFSETS,    TYPE_LONG, 1, 0) # placeholder
      add_sub(TAG_ROWS_PER_STRIP,   TYPE_LONG, 1, @height)
      add_sub(TAG_STRIP_BYTE_COUNTS, TYPE_LONG, 1, strip_bytes)
    end

    # ── EXIF sub-IFD ──

    def build_exif_ifd_entries
      add_exif(TYPE_SHORT, 4, [48, 50, 50, 48], tag: 0xA005) # ExifVersion 0220
      add_exif_rational(TAG_EXPOSURE_TIME, @exif_exposure_time) if @exif_exposure_time
      add_exif_rational(TAG_FNUMBER, @exif_f_number) if @exif_f_number
      add_exif_long(TAG_ISO_SPEED, @exif_iso) if @exif_iso
      add_exif_rational(TAG_FOCAL_LENGTH, @exif_focal_length) if @exif_focal_length
      add_exif_ascii(TAG_DATETIME_ORIGINAL, @exif_date_time_original) if @exif_date_time_original
    end

    # ── TIFF primitives (little-endian) ──

    def tiff_header(root_ifd_offset)
      "II".b + [42].pack("v") + [root_ifd_offset].pack("V")
    end

    def build_ifd_binary(entries, next_ifd_offset)
      sorted = entries.sort_by { |e| e[:tag] }
      parts = [sorted.length].pack("v")
      sorted.each do |e|
        parts << [e[:tag]].pack("v")
        parts << [e[:type]].pack("v")
        parts << [e[:count]].pack("V")
        parts << pack_inline_or_offset(e)
      end
      parts << [next_ifd_offset].pack("V")
      parts
    end

    def pack_inline_or_offset(entry)
      type, count, value = entry[:type], entry[:count], entry[:value]

      inline_bytes = case type
                     when TYPE_BYTE     then count
                     when TYPE_ASCII    then count
                     when TYPE_SHORT    then count * 2
                     when TYPE_LONG     then count * 4
                     when TYPE_RATIONAL then count * 8
                     when TYPE_SRATIONAL then count * 8
                     else 0
                     end

      if inline_bytes > 4
        return [entry[:offset]].pack("V")
      end

      case type
      when TYPE_BYTE
        if count == 1
          [value].pack("C") + "\0" * 3
        else
          (value.pack("C*") + "\0" * 4)[0, 4]
        end
      when TYPE_ASCII
        (value + "\0").ljust(4, "\0").b
      when TYPE_SHORT
        if count == 1
          [value].pack("v") + "\0\0"
        else
          (value.pack("v*") + "\0\0\0\0")[0, 4]
        end
      when TYPE_LONG
        [value].pack("V")
      when TYPE_RATIONAL
        if value.is_a?(Array) && value[0].is_a?(Array)
          [value[0][0], value[0][1]].pack("VV")
        else
          [value].pack("V")
        end
      when TYPE_SRATIONAL
        if value.is_a?(Array) && value[0].is_a?(Array)
          [value[0][0], value[0][1]].pack("VV")
        else
          [value].pack("V")
        end
      else
        "\0" * 4
      end
    end

    # ── Size precomputation (deterministic from entry metadata) ──

    def ifd_binary_size(entries)
      2 + (entries.length * 12) + 4 # count + entries + next_ifd
    end

    def external_data_size(entries)
      total = 0
      entries.each do |e|
        next if inline?(e)
        data_size = case e[:type]
                    when TYPE_BYTE     then e[:count]
                    when TYPE_ASCII    then e[:count]
                    when TYPE_SHORT    then e[:count] * 2
                    when TYPE_LONG     then e[:count] * 4
                    when TYPE_RATIONAL then e[:count] * 8
                    when TYPE_SRATIONAL then e[:count] * 8
                    else 0
                    end
        total += data_size + (4 - (data_size % 4)) % 4
      end
      total
    end

    def set_external_offsets(entries, base_offset)
      current = base_offset
      entries.each do |e|
        next if inline?(e)
        e[:offset] = current
        data_size = case e[:type]
                    when TYPE_BYTE     then e[:count]
                    when TYPE_ASCII    then e[:count]
                    when TYPE_SHORT    then e[:count] * 2
                    when TYPE_LONG     then e[:count] * 4
                    when TYPE_RATIONAL then e[:count] * 8
                    when TYPE_SRATIONAL then e[:count] * 8
                    else 0
                    end
        current += data_size + (4 - (data_size % 4)) % 4
      end
    end

    def build_image_data
      parts = []
      @raw_data.each do |row|
        parts << row.pack("v*")
      end
      parts.join
    end

    # ── External data (little-endian) ──

    def build_external_data(entries)
      data_parts = []
      entries.each do |e|
        next if inline?(e)
        data = pack_external(e)
        data_parts << data
        pad = (4 - (data.bytesize % 4)) % 4
        data_parts << "\0" * pad if pad > 0
      end
      data_parts.join
    end

    def inline?(entry)
      case entry[:type]
      when TYPE_BYTE     then entry[:count] <= 4
      when TYPE_ASCII    then entry[:count] <= 4
      when TYPE_SHORT    then entry[:count] <= 2
      when TYPE_LONG     then entry[:count] <= 1
      when TYPE_RATIONAL then false
      when TYPE_SRATIONAL then false
      else false
      end
    end

    def pack_external(entry)
      case entry[:type]
      when TYPE_BYTE
        entry[:value].pack("C*")
      when TYPE_ASCII
        s = entry[:value].is_a?(String) ? entry[:value] : entry[:value].to_s
        s + "\0"
      when TYPE_SHORT
        entry[:value].pack("v*")
      when TYPE_LONG
        entry[:value].pack("V*")
      when TYPE_RATIONAL
        result = String.new(encoding: Encoding::BINARY, capacity: entry[:count] * 8)
        entry[:value].each { |n, d| result << [n.to_i, d.to_i].pack("VV") }
        result
      when TYPE_SRATIONAL
        result = String.new(encoding: Encoding::BINARY, capacity: entry[:count] * 8)
        entry[:value].each { |n, d| result << [n.to_i, d.to_i].pack("VV") }
        result
      else
        ""
      end
    end

    # ── Helpers ──

    def align4(offset)
      offset + ((4 - (offset % 4)) % 4)
    end

    def update_root_sub_ifds(offset)
      @root_entries.each do |e|
        if e[:tag] == TAG_SUB_IFDS
          e[:value] = offset
        end
      end
    end

    def update_root_exif_pointer(offset)
      @root_entries.each do |e|
        if e[:tag] == TAG_EXIF_IFD_POINTER
          e[:value] = offset
        end
      end
    end

    def update_sub_strip_offsets(offset)
      @sub_entries.each do |e|
        if e[:tag] == TAG_STRIP_OFFSETS
          e[:value] = offset
        end
      end
    end

    def add_root(tag, type, count, value)
      @root_entries << { tag: tag, type: type, count: count, value: value }
    end

    def add_sub(tag, type, count, value)
      @sub_entries << { tag: tag, type: type, count: count, value: value }
    end

    def add_exif(type, count, value, tag:)
      @exif_entries << { tag: tag, type: type, count: count, value: value }
    end

    def add_exif_rational(tag, rational_value)
      return unless rational_value
      rat = rational_value.is_a?(Rational) ? rational_value : Rational(rational_value)
      add_exif(TYPE_RATIONAL, 1, [[rat.numerator, rat.denominator]], tag: tag)
    end

    def add_exif_long(tag, int_value)
      return unless int_value
      add_exif(TYPE_LONG, 1, int_value.to_i, tag: tag)
    end

    def add_exif_ascii(tag, str_value)
      return unless str_value
      add_exif(TYPE_ASCII, str_value.bytesize + 1, str_value, tag: tag)
    end

    def to_rational_pair(v)
      r = Rational(v).abs
      max_den = 100_000
      n = (r.numerator * max_den / r.denominator).round
      [n, max_den]
    end
  end
end
