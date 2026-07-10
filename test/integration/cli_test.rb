# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class CLITest < Minitest::Test
  include TestHelper

  BIN_PATH = File.join(__dir__, "../../bin/kdc")

  def run_kdc(*args)
    stdout, stderr, status = Open3.capture3("bundle exec ruby -I lib #{BIN_PATH} #{args.join(' ')}")
    { stdout: stdout, stderr: stderr, status: status }
  end

  def test_help_flag
    result = run_kdc("--help")
    
    assert result[:status].success?
    assert_includes result[:stdout], "kdc - Pure Ruby"
    assert_includes result[:stdout], "-m, --metadata"
    assert_includes result[:stdout], "-c, --convert"
  end

  def test_metadata_flag
    result = run_kdc("-m", kdc_path("DC120-flash-raw.kdc"))
    
    assert result[:status].success?
    assert_includes result[:stdout], "Camera: dc120"
    assert_includes result[:stdout], "Raw dimensions: 848x976"
  end

  def test_convert_default_tiff
    Dir.mktmpdir do |dir|
      output = File.join(dir, "output.tif")
      result = run_kdc("-c", kdc_path("DC120-flash-raw.kdc"), "-o", output, "--no-color-correction")
      
      assert result[:status].success?, "Conversion failed: #{result[:stderr]}"
      assert File.exist?(output)
    end
  end

  def test_convert_png_via_extension
    Dir.mktmpdir do |dir|
      output = File.join(dir, "output.png")
      result = run_kdc("-c", kdc_path("DC120-flash-raw.kdc"), "-o", output, "--no-color-correction")
      
      assert result[:status].success?
      assert File.exist?(output)
      
      content = File.read(output, mode: "rb")
      assert_equal "\x89PNG\r\n\x1a\n".b, content[0, 8]
    end
  end

  def test_convert_tif_via_format_flag
    Dir.mktmpdir do |dir|
      output = File.join(dir, "output.txt")
      result = run_kdc("-c", kdc_path("DC120-flash-raw.kdc"), "-o", output, "-f", "tif", "--no-color-correction")
      
      assert result[:status].success?
      assert File.exist?(output)
      
      content = File.read(output, mode: "rb")
      assert_equal "MM".b, content[0, 2]
    end
  end

  def test_convert_png_via_format_flag
    Dir.mktmpdir do |dir|
      output = File.join(dir, "output.txt")
      result = run_kdc("-c", kdc_path("DC120-flash-raw.kdc"), "-o", output, "-f", "png", "--no-color-correction")
      
      assert result[:status].success?
      assert File.exist?(output)
      
      content = File.read(output, mode: "rb")
      assert_equal "\x89PNG\r\n\x1a\n".b, content[0, 8]
    end
  end

  def test_missing_file_returns_error
    result = run_kdc("-m", "/nonexistent/file.KDC")
    
    refute result[:status].success?
  end
end
