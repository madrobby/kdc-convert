# frozen_string_literal: true

require_relative "../test_helper"

class ExifTest < Minitest::Test
  def test_empty_constructor
    exif = KDC::Exif.new
    assert_nil exif.make
    assert_nil exif.model
    assert_nil exif.exposure_time
    assert_nil exif.f_number
    assert_nil exif.iso
    refute exif.flash_fired?
    assert_nil exif.focal_length
    assert_nil exif.date_time_original
    assert_nil exif.white_balance
    assert_nil exif.light_source
    assert_nil exif.exposure_program
    assert_nil exif.date_time
    assert_nil exif.software
  end

  def test_default_empty_hash
    exif = KDC::Exif.new({})
    assert_empty exif.raw_data
  end

  def test_make_string_accessor
    exif = KDC::Exif.new(make: "Eastman Kodak")
    assert_equal "Eastman Kodak", exif.make
  end

  def test_model_string_accessor
    exif = KDC::Exif.new(model: "DC120")
    assert_equal "DC120", exif.model
  end

  def test_exposure_time_rational_from_string
    exif = KDC::Exif.new(exposure_time: "1/125")
    assert_instance_of Rational, exif.exposure_time
    assert_equal Rational(1, 125), exif.exposure_time
  end

  def test_exposure_time_rational_from_integer
    exif = KDC::Exif.new(exposure_time: 125)
    assert_instance_of Rational, exif.exposure_time
    assert_equal Rational(1, 125), exif.exposure_time
  end

  def test_exposure_time_rational_from_rational
    exif = KDC::Exif.new(exposure_time: Rational(1, 250))
    assert_equal Rational(1, 250), exif.exposure_time
  end

  def test_exposure_time_nil_for_invalid
    exif = KDC::Exif.new(exposure_time: "invalid")
    assert_nil exif.exposure_time
  end

  def test_exposure_time_nil_for_nil
    exif = KDC::Exif.new(exposure_time: nil)
    assert_nil exif.exposure_time
  end

  def test_f_number_float
    exif = KDC::Exif.new(f_number: 2.8)
    assert_instance_of Float, exif.f_number
    assert_in_delta 2.8, exif.f_number, 0.001
  end

  def test_f_number_from_integer
    exif = KDC::Exif.new(f_number: 4)
    assert_instance_of Float, exif.f_number
    assert_in_delta 4.0, exif.f_number, 0.001
  end

  def test_f_number_from_string
    exif = KDC::Exif.new(f_number: "2.8")
    assert_instance_of Float, exif.f_number
    assert_in_delta 2.8, exif.f_number, 0.001
  end

  def test_f_number_nil_for_invalid
    exif = KDC::Exif.new(f_number: "abc")
    assert_nil exif.f_number
  end

  def test_iso_integer
    exif = KDC::Exif.new(iso: 100)
    assert_equal 100, exif.iso
  end

  def test_iso_from_string
    exif = KDC::Exif.new(iso: "200")
    assert_equal 200, exif.iso
  end

  def test_iso_nil_for_invalid
    exif = KDC::Exif.new(iso: "abc")
    assert_nil exif.iso
  end

  def test_flash_fired_true
    exif = KDC::Exif.new(flash: true)
    assert exif.flash_fired?
  end

  def test_flash_fired_false
    exif = KDC::Exif.new(flash: false)
    refute exif.flash_fired?
  end

  def test_flash_fired_from_integer_bitfield
    exif = KDC::Exif.new(flash: KDC::FLASH_BITFIRED)
    assert exif.flash_fired?
  end

  def test_flash_fired_from_integer_no_flash
    exif = KDC::Exif.new(flash: 0)
    refute exif.flash_fired?
  end

  def test_flash_fired_nil
    exif = KDC::Exif.new(flash: nil)
    assert_nil exif.flash_fired?
  end

  def test_flash_alias
    exif = KDC::Exif.new(flash: true)
    assert exif.flash
  end

  def test_focal_length_integer
    exif = KDC::Exif.new(focal_length: 200)
    assert_equal 200, exif.focal_length
  end

  def test_focal_length_from_string
    exif = KDC::Exif.new(focal_length: "300")
    assert_equal 300, exif.focal_length
  end

  def test_date_time_original_string
    exif = KDC::Exif.new(date_time_original: "2026:07:11 10:30:00")
    assert_equal "2026:07:11 10:30:00", exif.date_time_original
  end

  def test_date_time_string
    exif = KDC::Exif.new(date_time: "2026:07:11 10:30:00")
    assert_equal "2026:07:11 10:30:00", exif.date_time
  end

  def test_software_string
    exif = KDC::Exif.new(software: "kdc-convert 1.0")
    assert_equal "kdc-convert 1.0", exif.software
  end

  def test_white_balance_symbol
    exif = KDC::Exif.new(white_balance: 1)
    assert_equal :daylight, exif.white_balance
  end

  def test_white_balance_manual
    exif = KDC::Exif.new(white_balance: 255)
    assert_equal :manual, exif.white_balance
  end

  def test_white_balance_unknown
    exif = KDC::Exif.new(white_balance: 0)
    assert_equal :unknown, exif.white_balance
  end

  def test_white_balance_nil_for_invalid
    exif = KDC::Exif.new(white_balance: 999)
    assert_nil exif.white_balance
  end

  def test_light_source_symbol
    exif = KDC::Exif.new(light_source: 1)
    assert_equal :daylight, exif.light_source
  end

  def test_light_source_nil_for_invalid
    exif = KDC::Exif.new(light_source: 999)
    assert_nil exif.light_source
  end

  def test_exposure_program_symbol
    exif = KDC::Exif.new(exposure_program: 3)
    assert_equal :aperture_priority, exif.exposure_program
  end

  def test_exposure_program_manual
    exif = KDC::Exif.new(exposure_program: 1)
    assert_equal :manual, exif.exposure_program
  end

  def test_exposure_program_nil_for_invalid
    exif = KDC::Exif.new(exposure_program: 999)
    assert_nil exif.exposure_program
  end

  def test_unknown_keys_stored_in_raw_data
    exif = KDC::Exif.new(custom_tag: "some_value", another: 42)
    assert_equal "some_value", exif.raw_data[:custom_tag]
    assert_equal 42, exif.raw_data[:another]
  end

  def test_kodak_specific_tags_accessible_but_not_serialized
    exif = KDC::Exif.new(white_balance: 1, light_source: 1, maker_note: "secret")
    assert_equal :daylight, exif.white_balance
    assert_equal :daylight, exif.light_source
    assert_equal "secret", exif.instance_variable_get(:@maker_note)

    entries = exif.to_tiff_entries
    assert_empty entries
  end

  def test_to_s_empty
    exif = KDC::Exif.new
    assert_equal "(no EXIF data)", exif.to_s
  end

  def test_to_s_with_normalized_data
    exif = KDC::Exif.new(
      make: "Eastman Kodak",
      model: "DC120",
      exposure_time: Rational(1, 125),
      f_number: 2.8,
      iso: 100,
      focal_length: 200,
      flash: true,
      date_time_original: "2026:07:11 10:30:00",
      exposure_program: :aperture_priority,
      date_time: "2026:07:11 10:30:00",
      software: "kdc-convert"
    )

    output = exif.to_s
    assert output.include?("=== EXIF Metadata ===")
    assert output.include?("Make: Eastman Kodak")
    assert output.include?("Model: DC120")
    assert output.include?("ISO: 100")
    assert output.include?("200mm")
    assert output.include?("ƒ/2.8")
  end

  def test_to_s_with_raw_data_fallback
    exif = KDC::Exif.new(custom: "value", raw_tag: 42)
    output = exif.to_s
    assert output.include?("Unnormalized data")
    assert output.include?("custom: \"value\"")
  end

  def test_to_shot_summary_full
    exif = KDC::Exif.new(
      focal_length: 200,
      f_number: 2.8,
      exposure_time: Rational(1, 4)
    )
    assert_equal "200mm ƒ/2.8 0.25s", exif.to_shot_summary
  end

  def test_to_shot_summary_only_focal_length
    exif = KDC::Exif.new(focal_length: 200)
    assert_equal "200mm", exif.to_shot_summary
  end

  def test_to_shot_summary_only_aperture
    exif = KDC::Exif.new(f_number: 2.8)
    assert_equal "ƒ/2.8", exif.to_shot_summary
  end

  def test_to_shot_summary_only_exposure
    exif = KDC::Exif.new(exposure_time: Rational(1, 60))
    summary = exif.to_shot_summary
    assert summary.start_with?("0.")
    assert summary.end_with?("s")
  end

  def test_to_shot_summary_empty
    exif = KDC::Exif.new
    assert_equal "", exif.to_shot_summary
  end

  def test_to_shot_summary_missing_values_omitted
    exif = KDC::Exif.new(focal_length: 200, flash: true)
    assert_equal "200mm", exif.to_shot_summary
  end

  def test_to_tiff_entries_empty
    exif = KDC::Exif.new
    assert_empty exif.to_tiff_entries
  end

  def test_to_tiff_entries_with_make
    exif = KDC::Exif.new(make: "Eastman Kodak")
    entries = exif.to_tiff_entries
    assert_equal 1, entries.length
    tag, type, count, value = entries.first
    assert_equal 0x010F, tag
    assert_equal KDC::TIFF_TYPE_ASCII, type
    assert_equal 14, count  # "Eastman Kodak".bytesize + 1
    assert_equal "Eastman Kodak", value
  end

  def test_to_tiff_entries_with_model
    exif = KDC::Exif.new(model: "DC120")
    entries = exif.to_tiff_entries
    tag, type, _count, value = entries.first
    assert_equal 0x0110, tag
    assert_equal KDC::TIFF_TYPE_ASCII, type
    assert_equal "DC120", value
  end

  def test_to_tiff_entries_with_exposure_time
    exif = KDC::Exif.new(exposure_time: Rational(1, 125))
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x829A, tag
    assert_equal KDC::TIFF_TYPE_RATIONAL, type
    assert_equal 1, count
    assert_equal [1, 125], value
  end

  def test_to_tiff_entries_with_f_number
    exif = KDC::Exif.new(f_number: 2.8)
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x829D, tag
    assert_equal KDC::TIFF_TYPE_LONG, type
    assert_equal 1, count
    # Value is a packed IEEE 754 float as integer
    assert_instance_of Integer, value
  end

  def test_to_tiff_entries_with_iso
    exif = KDC::Exif.new(iso: 100)
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x8827, tag
    assert_equal KDC::TIFF_TYPE_SHORT, type
    assert_equal 1, count
    assert_equal 100, value
  end

  def test_to_tiff_entries_with_flash_fired
    exif = KDC::Exif.new(flash: true)
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x9209, tag
    assert_equal KDC::TIFF_TYPE_SHORT, type
    assert_equal 1, count
    assert_equal KDC::FLASH_BITFIRED, value
  end

  def test_to_tiff_entries_with_flash_not_fired
    exif = KDC::Exif.new(flash: false)
    entries = exif.to_tiff_entries
    tag, _type, _count, value = entries.first
    assert_equal 0, value
  end

  def test_to_tiff_entries_with_focal_length
    exif = KDC::Exif.new(focal_length: 200)
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x920A, tag
    assert_equal KDC::TIFF_TYPE_SHORT, type
    assert_equal 1, count
    assert_equal 200, value
  end

  def test_to_tiff_entries_with_date_time_original
    exif = KDC::Exif.new(date_time_original: "2026:07:11 10:30:00")
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x9003, tag
    assert_equal KDC::TIFF_TYPE_ASCII, type
    assert_equal "2026:07:11 10:30:00", value
  end

  def test_to_tiff_entries_with_exposure_program
    exif = KDC::Exif.new(exposure_program: :aperture_priority)
    entries = exif.to_tiff_entries
    tag, type, count, value = entries.first
    assert_equal 0x8822, tag
    assert_equal KDC::TIFF_TYPE_SHORT, type
    assert_equal 1, count
    assert_equal 3, value  # aperture_priority = 3
  end

  def test_to_tiff_entries_with_date_time
    exif = KDC::Exif.new(date_time: "2026:07:11 10:30:00")
    entries = exif.to_tiff_entries
    tag, type, _count, value = entries.first
    assert_equal 0x0132, tag
    assert_equal KDC::TIFF_TYPE_ASCII, type
    assert_equal "2026:07:11 10:30:00", value
  end

  def test_to_tiff_entries_with_software
    exif = KDC::Exif.new(software: "kdc-convert 1.0")
    entries = exif.to_tiff_entries
    tag, type, _count, value = entries.first
    assert_equal 0x0131, tag
    assert_equal KDC::TIFF_TYPE_ASCII, type
    assert_equal "kdc-convert 1.0", value
  end

  def test_to_tiff_entries_excludes_kodak_specific
    exif = KDC::Exif.new(
      make: "Kodak",
      white_balance: 1,
      light_source: 1,
      maker_note: "secret"
    )
    entries = exif.to_tiff_entries
    # Only Make should be serialized; Kodak-specific tags excluded
    assert_equal 1, entries.length
    assert_equal 0x010F, entries.first[0]
  end

  def test_to_tiff_entries_skips_nil_values
    exif = KDC::Exif.new(make: "Kodak", model: nil, iso: nil)
    entries = exif.to_tiff_entries
    assert_equal 1, entries.length
    assert_equal 0x010F, entries.first[0]
  end

  def test_to_tiff_entries_multiple_entries
    exif = KDC::Exif.new(
      make: "Kodak",
      model: "DC120",
      iso: 100,
      focal_length: 200
    )
    entries = exif.to_tiff_entries
    assert_equal 4, entries.length
    tags = entries.map(&:first).sort
    assert_equal [0x010F, 0x0110, 0x8827, 0x920A], tags
  end

  def test_serialize_calls_writer
    calls = []
    writer = Object.new
    def writer.calls
      @calls ||= []
    end
    def writer.add_exif_entry(*args)
      self.calls << args
    end

    exif = KDC::Exif.new(make: "Kodak", iso: 100)
    exif.serialize(writer)

    assert_equal 2, writer.calls.length
  end

  def test_serialize_empty_does_nothing
    calls = []
    writer = Object.new
    def writer.calls
      @calls ||= []
    end
    def writer.add_exif_entry(*_args)
      self.calls << 1
    end

    exif = KDC::Exif.new
    exif.serialize(writer)

    assert_equal 0, writer.calls.length
  end

  def test_all_tags_together
    exif = KDC::Exif.new(
      make: "Eastman Kodak",
      model: "DC120 ZOOM Digital Camera",
      exposure_time: "1/125",
      f_number: 4.0,
      iso: 200,
      date_time_original: "2026:01:15 08:45:00",
      flash: true,
      focal_length: 300,
      exposure_program: :aperture_priority,
      date_time: "2026:01:15 08:45:00",
      software: "kdc-convert"
    )

    entries = exif.to_tiff_entries
    assert_equal 11, entries.length

    tag_ids = entries.map(&:first).sort
    expected = [0x010F, 0x0110, 0x0131, 0x0132, 0x829A, 0x829D, 0x8822, 0x8827, 0x9003, 0x9209, 0x920A]
    assert_equal expected, tag_ids
  end

  def test_tag_id_constant_mapping
    assert_equal 0x010F, KDC::TAG_ID[:make]
    assert_equal 0x0110, KDC::TAG_ID[:model]
    assert_equal 0x829A, KDC::TAG_ID[:exposure_time]
    assert_equal 0x829D, KDC::TAG_ID[:f_number]
    assert_equal 0x8827, KDC::TAG_ID[:iso]
    assert_equal 0x9003, KDC::TAG_ID[:date_time_original]
    assert_equal 0x9209, KDC::TAG_ID[:flash]
    assert_equal 0x920A, KDC::TAG_ID[:focal_length]
    assert_equal 0x8822, KDC::TAG_ID[:exposure_program]
    assert_equal 0x0132, KDC::TAG_ID[:date_time]
    assert_equal 0x0131, KDC::TAG_ID[:software]
  end

  def test_whitelist_constant
    assert_equal 11, KDC::WHITELIST.length
    assert KDC::WHITELIST.include?(:make)
    assert KDC::WHITELIST.include?(:model)
    refute KDC::WHITELIST.include?(:white_balance)
    refute KDC::WHITELIST.include?(:light_source)
    refute KDC::WHITELIST.include?(:maker_note)
  end

  def test_raw_data_access
    exif = KDC::Exif.new(custom: "value")
    assert_equal({ custom: "value" }, exif.raw_data)
  end

  def test_raw_data_empty_for_known_tags_only
    exif = KDC::Exif.new(make: "Kodak")
    assert_empty exif.raw_data
  end

  def test_nil_values_not_in_tiff_entries
    exif = KDC::Exif.new(make: nil, model: nil)
    assert_empty exif.to_tiff_entries
  end

  def test_iso_zero_excluded
    exif = KDC::Exif.new(iso: 0)
    entries = exif.to_tiff_entries
    assert_empty entries
  end

  def test_focal_length_zero_excluded
    exif = KDC::Exif.new(focal_length: 0)
    entries = exif.to_tiff_entries
    assert_empty entries
  end

  def test_exposure_time_zero_excluded
    exif = KDC::Exif.new(exposure_time: 0)
    entries = exif.to_tiff_entries
    assert_empty entries
  end

  def test_f_number_zero_excluded
    exif = KDC::Exif.new(f_number: 0)
    entries = exif.to_tiff_entries
    assert_empty entries
  end
end
