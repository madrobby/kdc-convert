# frozen_string_literal: true

require_relative "../test_helper"

class TIFFParserTest < Minitest::Test
  include TestHelper

  def test_parse_kdc_returns_metadata
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert metadata.respond_to?(:camera_model)
    assert_equal :dc120, metadata.camera_model
    assert_equal 848, metadata.raw_width
    assert_equal 976, metadata.raw_height
  end

  def test_detect_camera_dc120
    assert_equal :dc120, KDC.detect_camera("Kodak DC120 ZOOM Digital Camera")
  end

  def test_detect_camera_dc50
    assert_equal :dc50, KDC.detect_camera("Kodak Digital Science DC50 Zoom Camera")
  end

  def test_detect_camera_unknown
    assert_equal :unknown, KDC.detect_camera("Some Other Camera")
  end

  def test_parse_tiff_header_big_endian
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    assert_equal "MM", metadata.header.byte_order
    assert_equal 42, metadata.header.magic
    assert_equal 8, metadata.header.ifd_offset
  end

  def test_extract_make_and_model
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert metadata.exif_tags[0x010F].include?("Eastman Kodak")
    assert metadata.exif_tags[0x0110].include?("DC120")
  end

  def test_extract_thumbnail_offset
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert_equal 15680, metadata.data_offset
    assert_equal 827648, metadata.data_size
  end

  def test_white_level_default
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert_equal 255, metadata.white_level
  end

  def test_black_level_default
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert_equal [0, 0, 0, 0], metadata.black_level
  end

  def test_pixel_aspect_dc120
    metadata = KDC.parse_kdc(kdc_path("DC120-flash-raw.kdc"))
    
    assert_in_delta 1.5345911949685533, metadata.pixel_aspect, 0.0001
  end
end
