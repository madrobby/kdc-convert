# frozen_string_literal: true

require_relative "../test_helper"

class MetadataTest < Minitest::Test
  def test_constructor_with_valid_hash
    metadata = KDC::Metadata.new(
      make: "Test Camera",
      model: "Test Model",
      flash: 24,
      exposure_time: Rational(1, 223),
      f_number: Rational(5, 2)
    )

    assert_equal "Test Camera", metadata.make
    assert_equal "Test Model", metadata.model
    assert_equal 24, metadata.flash
    assert_equal Rational(1, 223), metadata.exposure_time
    assert_equal Rational(5, 2), metadata.f_number
  end

  def test_constructor_normalizes_rational_strings
    metadata = KDC::Metadata.new(
      exposure_time: "1/223",
      f_number: "2.5"
    )

    assert_equal Rational(1, 223), metadata.exposure_time
    assert_equal Rational(5, 2), metadata.f_number
  end

  def test_constructor_warns_on_invalid_key
    warn_output = capture_stderr { KDC::Metadata.new(invalid_key: "value") }
    assert_includes warn_output, "Unknown metadata key"
  end

  def test_constructor_warns_on_invalid_value_format
    warn_output = capture_stderr { KDC::Metadata.new(exposure_time: "invalid") }
    assert_includes warn_output, "Invalid value for Exposure Time"
  end

  def test_set_method_updates_values
    metadata = KDC::Metadata.new(make: "Original")
    metadata.set(make: "Updated")
    assert_equal "Updated", metadata.make
  end

  def test_set_method_warns_on_invalid_key
    warn_output = capture_stderr { KDC::Metadata.new.set(invalid_key: "value") }
    assert_includes warn_output, "Unknown metadata key"
  end

  def test_to_exif_returns_only_exif_mapped_keys
    metadata = KDC::Metadata.new(
      make: "Test",
      model: "Model",
      kdc_camera: :dc120,
      kdc_data_offset: 1000
    )

    exif = metadata.to_exif
    assert exif.key?(0x010F), "Should include Make (0x010F)"
    assert exif.key?(0x0110), "Should include Model (0x0110)"
    refute exif.key?(:kdc_camera), "Should not include KDC-specific keys"
    refute exif.key?(:kdc_data_offset), "Should not include KDC-specific keys"
  end

  def test_to_exif_values_are_canonical
    metadata = KDC::Metadata.new(
      exposure_time: "1/223",
      f_number: "2.5"
    )

    exif = metadata.to_exif
    assert exif[0x829A].is_a?(Rational), "ExposureTime should be Rational"
    assert exif[0x829D].is_a?(Rational), "FNumber should be Rational"
  end

  def test_to_s_includes_standard_and_kdc_fields
    metadata = KDC::Metadata.new(
      make: "Test",
      kdc_camera: :dc120
    )

    output = metadata.to_s
    assert_includes output, "Make: Test"
    assert_includes output, "Camera: dc120"
  end

  def test_method_missing_provides_accessors
    metadata = KDC::Metadata.new(make: "Test")
    assert_equal "Test", metadata.make
  end

  def test_method_missing_raises_for_unknown_fields
    metadata = KDC::Metadata.new
    assert_raises(NoMethodError) { metadata.nonexistent_field }
  end

  def test_flash_normalization
    metadata = KDC::Metadata.new(flash: 24)
    assert_equal 24, metadata.flash
  end

  def test_rational_parsing
    metadata = KDC::Metadata.new(exposure_time: "1/223")
    assert_equal Rational(1, 223), metadata.exposure_time
  end

  def test_array_normalization
    metadata = KDC::Metadata.new(cfa_pattern: [1, 0, 2, 1])
    assert_equal [1, 0, 2, 1], metadata.cfa_pattern
  end

  private

  def capture_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end
