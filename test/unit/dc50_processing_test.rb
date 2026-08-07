# frozen_string_literal: true

require_relative "../test_helper"

class DC50ProcessingTest < Minitest::Test
  def test_matrix_transforms_values
    image = [[[1000, 2000, 500]]]
    result = KDC::DC50Processing.apply_matrix(image)
    refute_equal image[0][0], result[0][0]
    result[0][0].each { |v| assert v >= 0, "Channel value should be non-negative" }
  end

  def test_matrix_clamps_at_65535
    # Large values that should be clamped
    image = [[[60000, 60000, 60000]]]
    result = KDC::DC50Processing.apply_matrix(image)
    result[0][0].each { |v| assert v <= 65535, "Channel value should be clamped to 65535" }
  end

  def test_gamma_applies_tone_curve
    # Uniform image at mid-level
    image = Array.new(10) { Array.new(10) { [3000, 3000, 3000] } }
    result = KDC::DC50Processing.apply_gamma(image)
    # Gamma should transform values
    assert result[0][0][0] != 3000, "Gamma should change the value"
  end

  def test_gamma_handles_zero_values
    image = Array.new(10) { Array.new(10) { [0, 0, 0] } }
    result = KDC::DC50Processing.apply_gamma(image)
    result[0][0].each { |v| assert v >= 0, "Should not go negative" }
  end

  def test_gamma_clamps_at_65535
    image = Array.new(10) { Array.new(10) { [65535, 65535, 65535] } }
    result = KDC::DC50Processing.apply_gamma(image)
    result[0][0].each { |v| assert v <= 65535, "Should clamp at 65535" }
  end
end
