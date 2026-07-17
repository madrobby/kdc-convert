# frozen_string_literal: true

require "stringio"

module KDC
  # Write 16-bit TIFF files with EXIF metadata
  class TIFFWriter
    TAG_IMAGE_WIDTH       = 0x0100
    TAG_IMAGE_LENGTH      = 0x0101
    TAG_BITS_PER_SAMPLE   = 0x0102
    TAG_COMPRESSION       = 0x0103
    TAG_PHOTOMETRIC_INTERP = 0x0106
    TAG_SAMPLES_PER_PIXEL = 0x0115
    TAG_ROWS_PER_STRIP    = 0x0116
    TAG_STRIP_BYTE_COUNTS = 0x0117
    TAG_X_RESOLUTION      = 0x011A
    TAG_Y_RESOLUTION      = 0x011B
    TAG_PLANAR_CONFIGURATION = 0x011C
    TAG_RESOLUTION_UNIT   = 0x0128
    TAG_MAKE              = 0x010F
    TAG_MODEL             = 0x0110
    TAG_EXPOSURE_TIME     = 0x0202
    TAG_FNUMBER           = 0x0203
    TAG_ISO_SPEED         = 0x0205
    TAG_DATETIME_ORIGINAL = 0x0206

    TIFF_TYPE_BYTE  = 1
    TIFF_TYPE_ASCII = 2
    TIFF_TYPE_SHORT = 3
    TIFF_TYPE_LONG  = 4
    TIFF_TYPE_RATIONAL = 5

    def initialize(width, height, bits = 16)
      @width = width
      @height = height
      @bits = bits
      @ifd_entries = []
      @exif_entries = []
    end

    def set_image_data(image_data)
      @image_data = image_data
    end

    def add_entry(tag, type, count, value)
      @ifd_entries << [tag, type, count, value]
    end

    def add_exif_entry(tag, type, count, value)
      @exif_entries << [tag, type, count, value]
    end

    def set_camera_info(make:, model:)
      add_entry(TAG_MAKE, TIFF_TYPE_ASCII, make.bytesize + 1, make)
      add_entry(TAG_MODEL, TIFF_TYPE_ASCII, model.bytesize + 1, model)
    end

    # Set metadata from KDC::Metadata instance
    def set_metadata(metadata)
      return unless metadata

      exif_hash = metadata.to_exif

      # Add standard EXIF entries to EXIF sub-IFD (standard TIFF tags 0x0000-0x014F belong in IFD0; EXIF tags start at 0x8200)
      exif_hash.each do |tag, value|
        next if tag < 0x8200

        begin
          if value.is_a?(String)
            add_exif_entry(tag, TIFF_TYPE_ASCII, value.bytes.length + 1, value)
          elsif value.is_a?(Integer)
            add_exif_entry(tag, TIFF_TYPE_SHORT, 1, value)
          elsif value.is_a?(Rational)
            add_exif_entry(tag, TIFF_TYPE_RATIONAL, 1, [value.numerator, value.denominator])
          elsif value.is_a?(Array)
            # For array values (like CFA pattern), pack as multiple shorts
            add_exif_entry(tag, TIFF_TYPE_SHORT, value.length, value)
          end
        rescue => e
          Util.warn("Failed to add EXIF tag 0x#{tag.to_s(16)}: #{e.message}")
        end
      end
    end

    def setup_image_info
      num_samples = 3
      row_bytes = @width * num_samples * (@bits / 8)
      strip_bytes = row_bytes * @height

      add_entry(TAG_IMAGE_WIDTH, TIFF_TYPE_SHORT, 1, @width)
      add_entry(TAG_IMAGE_LENGTH, TIFF_TYPE_SHORT, 1, @height)
      add_entry(TAG_BITS_PER_SAMPLE, TIFF_TYPE_SHORT, num_samples, [@bits] * num_samples)
      add_entry(TAG_COMPRESSION, TIFF_TYPE_SHORT, 1, 1)
      add_entry(TAG_PHOTOMETRIC_INTERP, TIFF_TYPE_SHORT, 1, 2)
      add_entry(TAG_SAMPLES_PER_PIXEL, TIFF_TYPE_SHORT, 1, num_samples)
      add_entry(TAG_STRIP_OFFSETS, TIFF_TYPE_LONG, 1, 0)
      add_entry(TAG_ROWS_PER_STRIP, TIFF_TYPE_LONG, 1, @height)
      add_entry(TAG_STRIP_BYTE_COUNTS, TIFF_TYPE_LONG, 1, strip_bytes)
      add_entry(TAG_X_RESOLUTION, TIFF_TYPE_RATIONAL, 1, [72, 1])
      add_entry(TAG_Y_RESOLUTION, TIFF_TYPE_RATIONAL, 1, [72, 1])
      add_entry(TAG_PLANAR_CONFIGURATION, TIFF_TYPE_SHORT, 1, 1)
      add_entry(TAG_RESOLUTION_UNIT, TIFF_TYPE_SHORT, 1, 2)
    end

    def write(output_path)
      # Calculate sizes
      header_size = 8
      ifd0_size = 2 + @ifd_entries.length * 12 + 4
      ifd0_offset = header_size

      has_exif = @exif_entries.any?
      if has_exif
        exif_ifd_offset = ifd0_offset + ifd0_size
        exif_size = 2 + @exif_entries.length * 12 + 4
        exif_end = exif_ifd_offset + exif_size
      else
        exif_ifd_offset = 0
        exif_end = ifd0_offset + ifd0_size
      end

      # Calculate external data offsets and build external data simultaneously
      ext_offset = exif_end
      external_data_parts = []

      # Helper to append data with 4-byte alignment
      add_aligned = ->(data) {
        external_data_parts << data
        ext_offset += data.bytesize
        padding = (4 - (ext_offset % 4)) % 4
        external_data_parts << "\0" * padding if padding > 0
        ext_offset += padding
      }

      # Process IFD0 entries - move values that don't fit inline (4 bytes) to external data
      @ifd_entries.each do |entry|
        type, count, value = entry[1], entry[2], entry[3]
        if type == TIFF_TYPE_ASCII && count > 4
          str = value.is_a?(String) ? value : value.to_s
          entry[3] = ext_offset
          add_aligned.call(str + "\0")
        elsif type == TIFF_TYPE_RATIONAL
          if value.is_a?(Array) && value.length == 2
            entry[3] = ext_offset
            add_aligned.call([value[0], value[1]].pack("NN"))
          end
        elsif type == TIFF_TYPE_SHORT && count > 2
          entry[3] = ext_offset
          add_aligned.call(value.pack("n*"))
        elsif type == TIFF_TYPE_LONG && count > 1
          entry[3] = ext_offset
          add_aligned.call(value.pack("N*"))
        elsif type == TIFF_TYPE_BYTE && count > 4
          entry[3] = ext_offset
          add_aligned.call(value.pack("C*"))
        end
      end

      # Process EXIF entries
      @exif_entries.each do |entry|
        type, count, value = entry[1], entry[2], entry[3]
        if type == TIFF_TYPE_ASCII && count > 4
          str = value.is_a?(String) ? value : value.to_s
          entry[3] = ext_offset
          add_aligned.call(str + "\0")
        elsif type == TIFF_TYPE_RATIONAL
          if value.is_a?(Array) && value.length == 2
            entry[3] = ext_offset
            add_aligned.call([value[0], value[1]].pack("NN"))
          end
        elsif type == TIFF_TYPE_SHORT && count > 2
          entry[3] = ext_offset
          add_aligned.call(value.pack("n*"))
        elsif type == TIFF_TYPE_LONG && count > 1
          entry[3] = ext_offset
          add_aligned.call(value.pack("N*"))
        elsif type == TIFF_TYPE_BYTE && count > 4
          entry[3] = ext_offset
          add_aligned.call(value.pack("C*"))
        end
      end

      image_offset = ext_offset

      # Update strip offset
      @ifd_entries.each do |entry|
        if entry[0] == TAG_STRIP_OFFSETS
          entry[3] = image_offset
          break
        end
      end

      # Sort IFD entries by tag ID (TIFF spec requires ascending order)
      sorted_ifd = @ifd_entries.sort_by { |e| e[0] }
      sorted_exif = @exif_entries.sort_by { |e| e[0] }

      # Build TIFF
      external_data = external_data_parts.join
      tiff = build_header
      tiff += build_ifd(sorted_ifd, exif_ifd_offset)
      tiff += build_ifd(sorted_exif, 0) if has_exif
      tiff += external_data
      tiff += build_image_data

      File.write(output_path, tiff)
    end

    private

    def build_header
      "MM".b + [42].pack("n") + [8].pack("N")
    end

    def build_ifd(entries, next_ifd)
      parts = []
      parts << [entries.length].pack("n")
      entries.each do |tag, type, count, value|
        parts << [tag].pack("n")
        parts << [type].pack("n")
        parts << [count].pack("N")
        parts << pack_value(type, count, value)
      end
      parts << [next_ifd].pack("N")
      parts.join
    end

    def pack_value(type, count, value)
      # Determine if value fits inline (4 bytes)
      inline_bytes = case type
                     when TIFF_TYPE_BYTE then count
                     when TIFF_TYPE_ASCII then count
                     when TIFF_TYPE_SHORT then count * 2
                     when TIFF_TYPE_LONG then count * 4
                     when TIFF_TYPE_RATIONAL then count * 8
                     else 0
                     end

      if inline_bytes > 4
        # Value stored externally - pack offset as 4-byte LONG
        return [value].pack("N")
      end

      case type
      when TIFF_TYPE_BYTE
        if count == 1
          [value].pack("C") + "\0" * 3
        else
          (value.pack("C*") + "\0" * 4)[0, 4]
        end
      when TIFF_TYPE_ASCII
        if value.is_a?(String)
          # Pack string with null termination, padded to exactly 4 bytes
          (value + "\0").ljust(4, "\0").b
        else
          [value].pack("N")
        end
      when TIFF_TYPE_SHORT
        if count == 1
          [value].pack("n") + "\0\0"
        else
          (value.pack("n*") + "\0\0\0\0")[0, 4]
        end
      when TIFF_TYPE_LONG
        if count == 1
          [value].pack("N")
        else
          (value.pack("N*") + "\0\0\0\0")[0, 4]
        end
      when TIFF_TYPE_RATIONAL
        if value.is_a?(Array)
          [value[0], value[1]].pack("NN")[0, 4]
        else
          [value].pack("N")
        end
      else
        "\0" * 4
      end
    end

    def build_image_data
      parts = []
      if @bits == 8
        @image_data.each do |row|
          row_parts = []
          row.each do |r, g, b|
            row_parts << [r, g, b].pack("C*")
          end
          parts << row_parts.join
        end
      else
        @image_data.each do |row|
          row_parts = []
          row.each do |r, g, b|
            row_parts << [r, g, b].pack("n*")
          end
          parts << row_parts.join
        end
      end
      parts.join
    end
  end
end
