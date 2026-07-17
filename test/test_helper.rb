# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/kdc"
require "fileutils"
require "tmpdir"
require "ostruct"

module TestHelper
  FIXTURES_PATH = File.join(__dir__, "fixtures")

  def kdc_path(filename)
    File.join(FIXTURES_PATH, filename)
  end
  alias_method :image_path, :kdc_path

  def reference_tiff_path
    File.join(FIXTURES_PATH, "DC120_1_ref_8.tif")
  end

  def reference_tiff_path_16
    File.join(FIXTURES_PATH, "DC120_1_ref_16.tif")
  end

  def reference_png_path
    File.join(FIXTURES_PATH, "DC120_1_ref.png")
  end

  def reference_tiff_path_2
    File.join(FIXTURES_PATH, "DC120_2_ref_8.tif")
  end

  def reference_tiff_path_2_16
    File.join(FIXTURES_PATH, "DC120_2_ref_16.tif")
  end

  def convert_to_temp(kdc_file, format: :tif, bit_depth: 8)
    Dir.mktmpdir do |dir|
      ext = format == :tif ? ".tif" : ".png"
      output = File.join(dir, "output#{ext}")

      converter = KDC::Converter.new(kdc_file, color_lut: nil, remove_stuck_pixels: false)
      if format == :tif
        converter.convert_to_tiff(output, bit_depth: bit_depth)
      else
        converter.convert_to_png(output)
      end

      yield output
    end
  end

  def file_sha256(path)
    require "digest"
    Digest::SHA256.file(path).hexdigest
  end
end
