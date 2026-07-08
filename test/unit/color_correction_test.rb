# frozen_string_literal: true

require_relative "../test_helper"

class ColorCorrectionTest < Minitest::Test
  def test_load_lut_missing_file
    result = KDC::ColorCorrection.load_lut("/nonexistent/path.json")
    assert_nil result
  end

  def test_load_lut_valid_file
    lut_path = File.join(__dir__, "../../reference_lut.json")
    result = KDC::ColorCorrection.load_lut(lut_path)
    
    assert_instance_of Hash, result
    assert result.key?("cameras")
  end

  def test_select_params_flash
    lut = {
      "cameras" => {
        "DC120" => {
          "flash_params" => {
            "linear" => { "R" => { "gain" => 1.0, "offset" => 0.0 } },
            "stretch" => nil
          }
        }
      }
    }
    
    result = KDC::ColorCorrection.select_params(lut, true, camera: "DC120")
    
    assert_instance_of Hash, result
    assert result.key?(:params)
  end

  def test_select_params_nonflash
    lut = {
      "cameras" => {
        "DC120" => {
          "nonflash_params" => {
            "linear" => { "R" => { "gain" => 1.5, "offset" => -10.0 } },
            "stretch" => nil
          }
        }
      }
    }
    
    result = KDC::ColorCorrection.select_params(lut, false, camera: "DC120")
    
    assert_instance_of Hash, result
    assert result.key?(:params)
    assert_equal 1.5, result[:params]["R"]["gain"]
  end

  def test_apply_basic
    image = [[[256, 512, 768]]]
    
    params = {
      "R" => { "gain" => 1.0, "offset" => 0.0 },
      "G" => { "gain" => 1.0, "offset" => 0.0 },
      "B" => { "gain" => 1.0, "offset" => 0.0 }
    }
    
    result = KDC::ColorCorrection.apply(image, params, nil)
    
    assert_instance_of Array, result
    assert_equal 256, result[0][0][0]
  end
end
