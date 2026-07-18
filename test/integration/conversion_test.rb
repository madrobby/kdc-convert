# frozen_string_literal: true

  require_relative "../test_helper"
  require "json"

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

  def test_dc120_converts_to_dng
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :dng) do |output|
      assert File.exist?(output), "should produce DNG output"
      assert File.size(output) > 0, "DNG should be non-empty"

      content = File.read(output, mode: "rb")
      assert_equal "II".b, content[0, 2], "should be little-endian"
      assert_equal [42].pack("v"), content[2, 2], "should have TIFF magic"

      ifd0_off = content[4, 4].unpack1("V")
      assert ifd0_off > 8, "IFD0 should be after header"

      entries = content[ifd0_off, 2].unpack1("v")
      found_dngv = false
      found_subifds = false
      (0...entries).each do |i|
        eo = ifd0_off + 2 + i * 12
        tag = content[eo, 2].unpack1("v")
        found_dngv = true if tag == 0xC612
        found_subifds = true if tag == 0x014A
      end
      assert found_dngv, "should have DNGVersion tag (0xC612)"
      assert found_subifds, "should have SubIFDs tag (0x014A)"
    end
  end

  def test_dc120_1_dng_hash_matches_reference
    lut = load_test_lut
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :dng, color_lut: lut) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_dng_path)
      assert_equal expected_hash, actual_hash, "DNG output should match reference"
    end
  end

  def test_dc120_2_dng_hash_matches_reference
    lut = load_test_lut
    convert_to_temp(kdc_path("DC120-flash-high.kdc"), format: :dng, color_lut: lut) do |output|
      actual_hash = file_sha256(output)
      expected_hash = file_sha256(reference_dng_path_2)
      assert_equal expected_hash, actual_hash, "DNG output should match reference"
    end
  end

  def test_dc120_dng_contains_raw_bayer_dimensions
    width = 848
    height = 976
    convert_to_temp(kdc_path("DC120-flash-raw.kdc"), format: :dng) do |output|
      content = File.read(output, mode: "rb")
      # Read root IFD and find SubIFDs tag
      ifd0_off = content[4, 4].unpack1("V")
      entries = content[ifd0_off, 2].unpack1("v")
      subifd_offset = nil
      (0...entries).each do |i|
        eo = ifd0_off + 2 + i * 12
        tag = content[eo, 2].unpack1("v")
        if tag == 0x014A
          subifd_offset = content[eo + 8, 4].unpack1("V")
          break
        end
      end

      refute_nil subifd_offset, "should have SubIFDs tag"

      # Read SubIFD entries for raw dimensions
      raw_entries = content[subifd_offset, 2].unpack1("v")
      raw_width = nil
      raw_height = nil
      (0...raw_entries).each do |i|
        eo = subifd_offset + 2 + i * 12
        tag = content[eo, 2].unpack1("v")
        val = content[eo + 8, 4].unpack1("V")
        raw_width = val if tag == 0x0100
        raw_height = val if tag == 0x0101
      end

      assert_equal width, raw_width, "raw width should be #{width}"
      assert_equal height, raw_height, "raw height should be #{height}"
    end
  end
end
