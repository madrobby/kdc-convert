# frozen_string_literal: true

require "stringio"

module KDC
  # TIFF tag types
  TIFF_TYPE_BYTE  = 1
  TIFF_TYPE_ASCII = 2
  TIFF_TYPE_SHORT = 3
  TIFF_TYPE_LONG  = 4
  TIFF_TYPE_RATIONAL = 5

  # Standard TIFF tags
  TAG_IMAGE_WIDTH       = 0x0100
  TAG_IMAGE_LENGTH      = 0x0101
  TAG_BITS_PER_SAMPLE   = 0x0102
  TAG_COMPRESSION       = 0x0103
  TAG_PHOTOMETRIC_INTERP = 0x0106
  TAG_MAKE              = 0x010F
  TAG_MODEL             = 0x0110
  TAG_STRIP_OFFSETS     = 0x0111
  TAG_ORIENTATION       = 0x0112
  TAG_SAMPLES_PER_PIXEL = 0x0115
  TAG_ROWS_PER_STRIP    = 0x0116
  TAG_STRIP_BYTE_COUNTS = 0x0117
  TAG_X_RESOLUTION      = 0x011A
  TAG_Y_RESOLUTION      = 0x011B
  TAG_RESOLUTION_UNIT   = 0x0128
  TAG_SOFTWARE          = 0x0131
  TAG_DATETIME          = 0x0132
  TAG_WHITE_BALANCE     = 0x8298
  TAG_EXPOSURE_TIME     = 0x829A
  TAG_FNUMBER           = 0x829D
  TAG_EXPOSURE_PROGRAM  = 0x8822
  TAG_ISO_SPEED         = 0x8827
  TAG_FOCAL_LENGTH      = 0x920A
  TAG_FLASH             = 0x9209
  TAG_DATETIME_ORIGINAL = 0x9003
  TAG_LIGHT_SOURCE      = 0x828F
  TAG_MAKER_NOTE        = 0x9216

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

  # Parsed KDC metadata
  KDCMetadata = Struct.new(
    :header,
    :ifds,
    :camera_model,
    :raw_width,
    :raw_height,
    :data_offset,
    :data_size,
    :compression,
    :white_level,
    :black_level,
    :cam_mul,
    :pixel_aspect,
    :exif_tags,
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
        rescue => e
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
        pos = io.pos
        io.pos = raw_value
        val = io.read(count).force_encoding("ASCII").sub(/\0+\z/, "")
        io.pos = pos
        val
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
        pos = io.pos
        io.pos = raw_value
        fmt = byte_order == "II" ? "v" : "n"
        vals = io.read(count * 2).unpack("#{fmt}*")
        io.pos = pos
        vals
      end
    when TIFF_TYPE_LONG
      if count == 1
        raw_value
      else
        # Multiple longs - read from offset
        pos = io.pos
        io.pos = raw_value
        fmt = byte_order == "II" ? "V" : "N"
        vals = io.read(count * 4).unpack("#{fmt}*")
        io.pos = pos
        vals
      end
    when TIFF_TYPE_RATIONAL
      if count == 1
        # Two longs: numerator, denominator
        if byte_order == "II"
          num = raw_value & 0xFFFFFFFF
          denom = (raw_value >> 32) & 0xFFFFFFFF
        else
          num = (raw_value >> 32) & 0xFFFFFFFF
          denom = raw_value & 0xFFFFFFFF
        end
        "#{num}/#{denom}"
      else
        # Multiple rationals - read from offset
        pos = io.pos
        io.pos = raw_value
        vals = []
        count.times do
          num = io.read(4).unpack1("V")
          denom = io.read(4).unpack1("V")
          vals << "#{num}/#{denom}"
        end
        io.pos = pos
        vals
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

      # Find Make and Model
      make_entry = find_tag(entries, TAG_MAKE)
      model_entry = find_tag(entries, TAG_MODEL)

      make = make_entry&.value
      model = model_entry&.value

      # Detect camera
      camera = detect_camera(model)

      # Extract key metadata
      comp_entry = find_tag(entries, TAG_COMPRESSION)
      offset_entry = find_tag(entries, TAG_STRIP_OFFSETS)
      bytes_entry = find_tag(entries, TAG_STRIP_BYTE_COUNTS)

      compression = comp_entry&.value || 1
      data_offset = offset_entry&.value || 0
      data_size = bytes_entry&.value || 0

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

      # White level (default for DC120)
      white_level = 510

      # Black level (DC120 has 0)
      black_level = [0, 0, 0, 0]

      # Camera white balance multipliers (default: unset)
      cam_mul = [0.0, 1.0, 0.0, 0.0]

      KDCMetadata.new(
        header: header,
        ifds: ifds,
        camera_model: camera,
        raw_width: raw_width,
        raw_height: raw_height,
        data_offset: data_offset,
        data_size: data_size,
        compression: compression,
        white_level: white_level,
        black_level: black_level,
        cam_mul: cam_mul,
        pixel_aspect: pixel_aspect,
        exif_tags: entries.to_h { |e| [e.tag, e.value] }
      )
    end
  end
end
