# frozen_string_literal: true

require_relative "../test_helper"

class ConversionTest < Minitest::Test
  include TestHelper

  TEST_FILES = %w[
    DC120-flash-raw.kdc
    DC120-flash-high.kdc
  ].freeze

  def test_all_kdc_files_convert_to_tiff
    file = TEST_FILES.first
    convert_to_temp(kdc_path(file), format: :tif) do |output|
      assert File.exist?(output), "#{file} should produce TIFF output"
      assert File.size(output) > 0, "#{file} TIFF should be non-empty"

      content = File.read(output, mode: "rb")
      assert_equal "MM".b, content[0, 2], "#{file} should be big-endian TIFF"
    end
  end

  def test_all_kdc_files_convert_to_png
    file = TEST_FILES.first
    convert_to_temp(kdc_path(file), format: :png) do |output|
      assert File.exist?(output), "#{file} should produce PNG output"
      assert File.size(output) > 0, "#{file} PNG should be non-empty"

      content = File.read(output, mode: "rb")
      assert_equal "\x89PNG\r\n\x1a\n".b, content[0, 8], "#{file} should have valid PNG signature"
    end
  end

  def test_output_dimensions
    file = TEST_FILES.first
    convert_to_temp(kdc_path(file), format: :tif) do |output|
      result = `file #{output}`
      assert_match(/width=1301/, result, "#{file} should be 1301 wide")
      assert_match(/height=976/, result, "#{file} should be 976 tall")
    end
  end

  def test_dc120_1_tiff_hash_matches_reference
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :tif) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_tiff_path)

      assert_equal expected_hash, actual_hash, "TIFF output should match reference"
    end
  end

  def test_dc120_1_png_hash_matches_reference
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :png) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_png_path)

      assert_equal expected_hash, actual_hash, "PNG output should match reference"
    end
  end

  def test_dc120_2_flash_high_tiff_hash_matches_reference
    convert_to_temp(kdc_path("DC120-flash-high.kdc"), format: :tif) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_tiff_path_2)

      assert_equal expected_hash, actual_hash, "TIFF output should match reference"
    end
  end

  def test_dc120_1_16bit_tiff_hash_matches_reference
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :tif, bit_depth: 16) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_tiff_path_16)

      assert_equal expected_hash, actual_hash, "16-bit TIFF output should match reference"
    end
  end

  def test_dc120_2_16bit_tiff_hash_matches_reference
    convert_to_temp(kdc_path("DC120-flash-high.kdc"), format: :tif, bit_depth: 16) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_tiff_path_2_16)

      assert_equal expected_hash, actual_hash, "16-bit TIFF output should match reference"
    end
  end
end
