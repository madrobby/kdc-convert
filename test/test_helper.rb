# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/kdc"
require "fileutils"
require "tmpdir"
require "ostruct"

module TestHelper
  TEST_IMAGES_PATH = File.join(__dir__, "images")

  def image_path(filename)
    File.join(TEST_IMAGES_PATH, filename)
  end
  
  def reference_tiff_path
    File.join(TEST_IMAGES_PATH, "DC120_1_ref.tif")
  end

  def reference_png_path
    File.join(TEST_IMAGES_PATH, "DC120_1_ref.png")
  end

  def convert_to_temp(kdc_file, format: :tif)
    Dir.mktmpdir do |dir|
      ext = format == :tif ? ".tif" : ".png"
      output = File.join(dir, "output#{ext}")
      
      converter = KDC::Converter.new(kdc_file, color_lut: nil)
      if format == :tif
        converter.convert_to_tiff(output)
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
