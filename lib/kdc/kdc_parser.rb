# frozen_string_literal: true

require "stringio"
require_relative "metadata"

module KDC
  # TIFF tag types
  TIFF_TYPE_BYTE  = 1
  TIFF_TYPE_ASCII = 2
  TIFF_TYPE_SHORT = 3
  TIFF_TYPE_LONG  = 4
  TIFF_TYPE_RATIONAL = 5

  # Standard TIFF tags
  TAG_SUBFILE_TYPE              = 0x00FD
  TAG_IMAGE_WIDTH               = 0x0100
  TAG_IMAGE_LENGTH              = 0x0101
  TAG_BITS_PER_SAMPLE           = 0x0102
  TAG_COMPRESSION               = 0x0103
  TAG_PHOTOMETRIC_INTERP        = 0x0106
  TAG_IMAGE_DESCRIPTION         = 0x010E
  TAG_MAKE                      = 0x010F
  TAG_MODEL                     = 0x0110
  TAG_STRIP_OFFSETS             = 0x0111
  TAG_ORIENTATION               = 0x0112
  TAG_SAMPLES_PER_PIXEL         = 0x0115
  TAG_ROWS_PER_STRIP            = 0x0116
  TAG_STRIP_BYTE_COUNTS         = 0x0117
  TAG_X_RESOLUTION              = 0x011A
  TAG_Y_RESOLUTION              = 0x011B
  TAG_PLANAR_CONFIGURATION      = 0x011C
  TAG_RESOLUTION_UNIT           = 0x0128
  TAG_SOFTWARE                  = 0x0131
  TAG_DATETIME                  = 0x0132
  TAG_EXPOSURE_VALUE            = 0x828A
  TAG_COMPRESSED_BITS_PER_PIXEL = 0x828B
  TAG_COMPRESSED_BITS_PER_PIXEL_EXIF = 0x9102
  TAG_SENSING_METHOD            = 0x828C
  TAG_CFA_REPEAT_PATTERN_DIM    = 0x828D
  TAG_CFA_PATTERN               = 0x828E
  TAG_COPYRIGHT                 = 0x829B
  TAG_WHITE_BALANCE             = 0x8298
  TAG_EXPOSURE_TIME             = 0x829A
  TAG_FNUMBER                   = 0x829D
  TAG_EXPOSURE_PROGRAM          = 0x8822
  TAG_ISO_SPEED                 = 0x8827
  TAG_FOCAL_LENGTH              = 0x920A
  TAG_FLASH                     = 0x9209
  TAG_DATETIME_ORIGINAL         = 0x9003
  TAG_LIGHT_SOURCE              = 0x9208
  TAG_SUBJECT_DISTANCE          = 0x920B
  TAG_MAKER_NOTE                = 0x9216
  TAG_TIFF_EP_STANDARD_ID       = 0xA433
  TAG_MAIN_IMAGE_OFFSET         = 0x014A

  # Camera model strings
  MODEL_DC120 = "Kodak DC120 ZOOM Digital Camera"
  MODEL_DC50  = "Kodak Digital Science DC50 Zoom Camera"

  # DC120 raw decoder shift tables (from LibRaw kodak_decoders.cpp)
  DC120_MUL = [162, 192, 187, 92].freeze
  DC120_ADD = [0, 636, 424, 212].freeze

  # DC120 sensor dimensions
  DC120_RAW_WIDTH  = 848
  DC120_RAW_HEIGHT = 976
  DC120_PIXEL_ASPECT = 1.5345911949685533

  class TIFFError < StandardError; end

  # TIFF Header
  TIFFHeader = Struct.new(
    :byte_order,
    :magic,
    :ifd_offset,
    keyword_init: true
  )

  # TIFF IFD Entry
  IFDEntry = Struct.new(
    :tag,
    :type,
    :count,
    :value,
    keyword_init: true
  )

  # TIFF IFD
  IFD = Struct.new(
    :entries,
    :next_ifd_offset,
    keyword_init: true
  )



  # Parse TIFF header
  def self.parse_tiff_header(io)
    byte_order = io.read(2)
    raise TIFFError, "Invalid byte order: #{byte_order.inspect}" unless byte_order == "II" || byte_order == "MM"

    magic = if byte_order == "II"
              io.read(2).unpack1("v")
            else
              io.read(2).unpack1("n")
            end
    raise TIFFError, "Invalid magic number: #{magic}" unless magic == 42

    ifd_offset = if byte_order == "II"
                   io.read(4).unpack1("V")
                 else
                   io.read(4).unpack1("N")
                 end

    TIFFHeader.new(
      byte_order: byte_order,
      magic: magic,
      ifd_offset: ifd_offset
    )
  end

  # Parse a single IFD
  def self.parse_ifd(io, ifd_offset, byte_order = "MM")
    io.pos = ifd_offset
    num_entries = if byte_order == "II"
                  io.read(2).unpack1("v")
                else
                  io.read(2).unpack1("n")
                end

    entries = []
    0.upto(num_entries - 1) do |i|
      entry_start = ifd_offset + 2 + i * 12
      io.pos = entry_start

      tag = if byte_order == "II"
            io.read(2).unpack1("v")
          else
            io.read(2).unpack1("n")
          end

      type = if byte_order == "II"
             io.read(2).unpack1("v")
           else
             io.read(2).unpack1("n")
           end

      count = if byte_order == "II"
              io.read(4).unpack1("V")
            else
              io.read(4).unpack1("N")
            end

      # Read the 4-byte value field
      raw_value = if byte_order == "II"
                  io.read(4).unpack1("V")
                else
                  io.read(4).unpack1("N")
                end

      # Extract the actual value based on type
      value = extract_value(type, count, raw_value, io, byte_order)

      entries << IFDEntry.new(
        tag: tag,
        type: type,
        count: count,
        value: value
      )
    end

    # Next IFD offset
    next_ifd_offset = if byte_order == "II"
                        io.read(4).unpack1("V")
                      else
                        io.read(4).unpack1("N")
                      end

    IFD.new(entries: entries, next_ifd_offset: next_ifd_offset)
  end

  # Extract value from raw 4-byte field based on type
  def self.extract_value(type, count, raw_value, io, byte_order)
    case type
    when TIFF_TYPE_BYTE
      if count == 1
        raw_value & 0xFF
      else
        # Multiple bytes - read from offset
        begin
          pos = io.pos
          io.pos = raw_value
          data = io.read(count)
          io.pos = pos
          data ? data.bytes : []
        rescue
          []
        end
      end
    when TIFF_TYPE_ASCII
      if count <= 4
        # Inline ASCII string
        str = [raw_value].pack("V").force_encoding("ASCII").sub(/\0+\z/, "")
        str
      else
        # Read from offset
        begin
          pos = io.pos
          io.pos = raw_value
          val = io.read(count)
          io.pos = pos
          val ? val.force_encoding("ASCII").sub(/\0+\z/, "") : nil
        rescue
          nil
        end
      end
    when TIFF_TYPE_SHORT
      if count == 1
        # Extract first 2 bytes from 4-byte field
        if byte_order == "II"
          (raw_value & 0xFFFF).to_i
        else
          ((raw_value >> 16) & 0xFFFF).to_i
        end
      else
        # Multiple shorts - read from offset
        begin
          pos = io.pos
          io.pos = raw_value
          fmt = byte_order == "II" ? "v" : "n"
          data = io.read(count * 2)
          io.pos = pos
          data ? data.unpack("#{fmt}*") : nil
        rescue
          nil
        end
      end
    when TIFF_TYPE_LONG
      if count == 1
        raw_value
      else
        # Multiple longs - read from offset
        begin
          pos = io.pos
          io.pos = raw_value
          fmt = byte_order == "II" ? "V" : "N"
          data = io.read(count * 4)
          io.pos = pos
          data ? data.unpack("#{fmt}*") : nil
        rescue
          nil
        end
      end
    when TIFF_TYPE_RATIONAL
      if count == 1
        # Read 8 bytes from offset (numerator and denominator)
        begin
          pos = io.pos
          io.pos = raw_value
          if byte_order == "II"
            num = io.read(4)&.unpack1("V")
            denom = io.read(4)&.unpack1("V")
          else
            num = io.read(4)&.unpack1("N")
            denom = io.read(4)&.unpack1("N")
          end
          io.pos = pos
          return nil unless num && denom

          "#{num}/#{denom}"
        rescue
          nil
        end
      else
        # Multiple rationals - read from offset
        begin
          pos = io.pos
          io.pos = raw_value
          vals = []
          count.times do
            if byte_order == "II"
              num = io.read(4)&.unpack1("V")
              denom = io.read(4)&.unpack1("V")
            else
              num = io.read(4)&.unpack1("N")
              denom = io.read(4)&.unpack1("N")
            end
            break if num.nil? || denom.nil?
            vals << "#{num}/#{denom}"
          end
          io.pos = pos
          vals.empty? ? nil : vals
        rescue
          nil
        end
      end
    else
      # Unknown type - return raw value
      raw_value
    end
  end

  # Parse all IFDs
  def self.parse_tiff_ifds(io, header)
    ifds = []
    offset = header.ifd_offset

    while offset != 0 && ifds.length < 20
      ifd = parse_ifd(io, offset, header.byte_order)
      ifds << ifd
      offset = ifd.next_ifd_offset
    end

    ifds
  end

  # Find a tag value in IFD entries
  def self.find_tag(ifd_entries, tag_id)
    ifd_entries.find { |e| e.tag == tag_id }
  end

  # Detect camera model
  def self.detect_camera(model)
    return nil unless model

    if model.include?("DC120")
      :dc120
    elsif model.include?("DC50")
      :dc50
    else
      :unknown
    end
  end

  # Main KDC parser
  def self.parse_kdc(file_path)
    File.open(file_path, "rb") do |io|
      # Parse TIFF header
      header = parse_tiff_header(io)

      # Parse all IFDs
      ifds = parse_tiff_ifds(io, header)

      # Get entries from first IFD
      entries = ifds.first&.entries || []

      # Find Model
      model_entry = find_tag(entries, TAG_MODEL)

      model = model_entry&.value

      # Detect camera
      camera = detect_camera(model)

      # Extract key metadata, preferring the second IFD (main image) if present
      second_ifd = nil
      main_offset_tag = find_tag(entries, TAG_MAIN_IMAGE_OFFSET)
      if main_offset_tag && main_offset_tag.value && main_offset_tag.value > 0
        begin
          second_ifd = parse_ifd(io, main_offset_tag.value, header.byte_order)
        rescue => e
          Util.warn("Failed to parse second IFD at offset #{main_offset_tag.value}: #{e.message}")
          second_ifd = nil
        end
      end

      second_entries = second_ifd&.entries || []
      comp_entry = find_tag(second_entries, TAG_COMPRESSION) || find_tag(entries, TAG_COMPRESSION)
      offset_entry = find_tag(second_entries, TAG_STRIP_OFFSETS) || find_tag(entries, TAG_STRIP_OFFSETS)
      bytes_entry = find_tag(second_entries, TAG_STRIP_BYTE_COUNTS) || find_tag(entries, TAG_STRIP_BYTE_COUNTS)

      compression = comp_entry&.value || 1
      data_offset = offset_entry&.value || 0
      data_size = bytes_entry&.value || 0

      # Compute quality based on camera-specific thresholds
      quality = case camera
                when :dc120
                  DC120Decoder.classify_quality(compression, data_size)
                when :dc50
                  :unknown
                else
                  :unknown
                end

      # Extract compressed bits per pixel from EXIF IFD or TIFF/EP tag
      cbpp_exif = find_tag_value(second_entries, TAG_COMPRESSED_BITS_PER_PIXEL_EXIF)
      if cbpp_exif.is_a?(String) && cbpp_exif.include?("/")
        cbpp_exif = cbpp_exif.split("/").first.to_i
      end
      compressed_bits_per_pixel = find_tag_value(entries, TAG_COMPRESSED_BITS_PER_PIXEL) || cbpp_exif

      # Set raw dimensions based on camera model
      raw_width, raw_height = case camera
                              when :dc120
                                [DC120_RAW_WIDTH, DC120_RAW_HEIGHT]
                              when :dc50
                                [768, 512]
                              else
                                [0, 0]
                              end

      # Pixel aspect ratio
      pixel_aspect = case camera
                     when :dc120
                       DC120_PIXEL_ASPECT
                     else
                       1.0
                     end

      # White level: 16383 for DC50 (PT tone curve maximum), 510 for DC120 compressed, 255 for DC120 uncompressed
      white_level = if camera == :dc50
                      16383
                    else
                      compression == 7 ? 510 : 255
                    end

      # Black level (DC120 has 0)
      black_level = [0, 0, 0, 0]

      # Camera white balance multipliers (default: unset)
      cam_mul = [0.0, 1.0, 0.0, 0.0]

      # Build hash for Metadata constructor
      metadata_hash = {
        # Standard EXIF fields
        make: find_tag_value(entries, TAG_MAKE),
        model: model,
        compression: compression,
        orientation: find_tag_value(entries, TAG_ORIENTATION),
        x_resolution: parse_rational_value(find_tag_value(entries, TAG_X_RESOLUTION)),
        y_resolution: parse_rational_value(find_tag_value(entries, TAG_Y_RESOLUTION)),
        resolution_unit: find_tag_value(entries, TAG_RESOLUTION_UNIT),
        software: find_tag_value(entries, TAG_SOFTWARE),
        date_time: find_tag_value(entries, TAG_DATETIME),
        exposure_time: parse_rational_value(find_tag_value(entries, TAG_EXPOSURE_TIME)),
        f_number: parse_rational_value(find_tag_value(entries, TAG_FNUMBER)),
        exposure_program: find_tag_value(entries, TAG_EXPOSURE_PROGRAM),
        iso: find_tag_value(entries, TAG_ISO_SPEED),
        focal_length: parse_rational_value(find_tag_value(entries, TAG_FOCAL_LENGTH)),
        flash: find_tag_value(entries, TAG_FLASH),
        date_time_original: find_tag_value(entries, TAG_DATETIME_ORIGINAL),
        light_source: find_tag_value(entries, TAG_LIGHT_SOURCE),

        # New tags from exiftool output
        subfile_type: find_tag_value(entries, TAG_SUBFILE_TYPE),
        image_width: find_tag_value(entries, TAG_IMAGE_WIDTH),
        image_length: find_tag_value(entries, TAG_IMAGE_LENGTH),
        bits_per_sample: find_tag_value(entries, TAG_BITS_PER_SAMPLE),
        photometric_interpretation: find_tag_value(entries, TAG_PHOTOMETRIC_INTERP),
        image_description: find_tag_value(entries, TAG_IMAGE_DESCRIPTION),
        strip_offsets: find_tag_value(second_entries, TAG_STRIP_OFFSETS) || find_tag_value(entries, TAG_STRIP_OFFSETS),
        samples_per_pixel: find_tag_value(entries, TAG_SAMPLES_PER_PIXEL),
        rows_per_strip: find_tag_value(entries, TAG_ROWS_PER_STRIP),
        strip_byte_counts: find_tag_value(second_entries, TAG_STRIP_BYTE_COUNTS) || find_tag_value(entries, TAG_STRIP_BYTE_COUNTS),
        planar_configuration: find_tag_value(entries, TAG_PLANAR_CONFIGURATION),
        exposure_value: parse_rational_value(find_tag_value(entries, TAG_EXPOSURE_VALUE)),
        compressed_bits_per_pixel: compressed_bits_per_pixel,
        sensing_method: find_tag_value(entries, TAG_SENSING_METHOD),
        cfa_repeat_pattern_dim: find_tag_value(entries, TAG_CFA_REPEAT_PATTERN_DIM),
        cfa_pattern: parse_cfa_pattern(find_tag_value(entries, TAG_CFA_PATTERN)),
        copyright: find_tag_value(entries, TAG_COPYRIGHT),
        subject_distance: parse_rational_value(find_tag_value(entries, TAG_SUBJECT_DISTANCE)),
        tif_ep_standard_id: find_tag_value(entries, TAG_TIFF_EP_STANDARD_ID),

        # KDC-specific fields
        kdc_camera: camera,
        kdc_data_offset: data_offset,
        kdc_data_size: data_size,
        kdc_white_level: white_level,
        kdc_black_level: black_level,
        kdc_raw_width: raw_width,
        kdc_raw_height: raw_height,
        kdc_pixel_aspect: Rational(pixel_aspect),
        kdc_quality: quality,
        kdc_cam_mul: cam_mul,
        kdc_compressed_bits_per_pixel: compressed_bits_per_pixel,

        # Internal structures
        header: header,
        ifds: ifds,
        second_ifd: second_ifd
      }

      KDC::Metadata.new(metadata_hash.compact)
    end
  end

  # Find a tag value from IFD entries
  def self.find_tag_value(entries, tag_id)
    entry = find_tag(entries, tag_id)
    entry&.value
  end

  # Parse a rational value from string "num/denom" to Rational
  def self.parse_rational_value(value)
    return nil unless value

    if value.is_a?(Rational)
      value
    elsif value.is_a?(String) && value.include?("/")
      parts = value.split("/").map(&:to_i)
      return nil unless parts.length == 2 && parts[1] != 0

      Rational(parts[0], parts[1])
    else
      value
    end
  end

  # Parse CFA pattern from string "1 0 2 1" to array [1, 0, 2, 1]
  def self.parse_cfa_pattern(value)
    return nil unless value

    if value.is_a?(Array)
      value.map(&:to_i)
    elsif value.is_a?(String)
      value.split(/\s+/).map(&:to_i)
    else
      nil
    end
  end
end
