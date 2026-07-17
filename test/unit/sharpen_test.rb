# frozen_string_literal: true

require_relative "../test_helper"

class SharpenTest < Minitest::Test
  def setup
    @width = 8
    @height = 8
    # Create a simple test image with a sharp edge
    @image = Array.new(@height) do |y|
      Array.new(@width) do |x|
        val = x < 4 ? 1000 : 20000
        [val, val, val]
      end
    end
  end

  def test_unsharp_mask_basic
    result = KDC::Sharpen.unsharp_mask(@image, radius: 1.0, amount: 1.0, threshold: 2)
    
    assert_instance_of Array, result
    assert_equal @height, result.length
    assert_equal @width, result[0].length
    assert_equal 3, result[0][0].length
  end

  def test_unsharp_mask_small_radius_produces_valid_output
    # Very small radius should still produce valid output without crashing
    result = KDC::Sharpen.unsharp_mask(@image, radius: 0.1, amount: 1.0, threshold: 2)
    
    @height.times do |y|
      @width.times do |x|
        3.times do |c|
          assert result[y][x][c] >= 0, "Value should be >= 0"
          assert result[y][x][c] <= 65535, "Value should be <= 65535"
        end
      end
    end
  end

  def test_unsharp_mask_zero_amount_noop
    result = KDC::Sharpen.unsharp_mask(@image, radius: 1.0, amount: 0.0, threshold: 2)
    
    @height.times do |y|
      @width.times do |x|
        assert_equal @image[y][x], result[y][x]
      end
    end
  end

  def test_unsharp_mask_high_threshold_suppresses
    # Create uniform image - no edges, so high threshold should suppress everything
    uniform = Array.new(8) { Array.new(8) { [10000, 10000, 10000] } }
    result = KDC::Sharpen.unsharp_mask(uniform, radius: 1.0, amount: 1.0, threshold: 5000)
    
    @height.times do |y|
      @width.times do |x|
        assert_equal uniform[y][x], result[y][x]
      end
    end
  end

  def test_unsharp_mask_clamps_at_0
    # Image with values near 0
    dark_image = Array.new(4) { Array.new(4) { [10, 10, 10] } }
    result = KDC::Sharpen.unsharp_mask(dark_image, radius: 1.0, amount: 10.0, threshold: 0)
    
    result.each do |row|
      row.each do |pixel|
        pixel.each do |v|
          assert v >= 0, "Value #{v} should be >= 0"
        end
      end
    end
  end

  def test_unsharp_mask_clamps_at_65535
    # Image with values near 65535
    bright_image = Array.new(4) { Array.new(4) { [65500, 65500, 65500] } }
    result = KDC::Sharpen.unsharp_mask(bright_image, radius: 1.0, amount: 10.0, threshold: 0)
    
    result.each do |row|
      row.each do |pixel|
        pixel.each do |v|
          assert v <= 65535, "Value #{v} should be <= 65535"
        end
      end
    end
  end

  def test_unsharp_mask_sharpens_edge
    # Create image with known edge
    edge_image = Array.new(8) do |y|
      Array.new(8) do |x|
        val = x < 4 ? 1000 : 20000
        [val, val, val]
      end
    end
    
    result = KDC::Sharpen.unsharp_mask(edge_image, radius: 1.0, amount: 1.0, threshold: 2)
    
    # Near the edge (x=3,4), values should be pushed further apart
    # Left of edge should be darker, right should be brighter
    left_val = result[4][3][0]
    right_val = result[4][4][0]
    
    # Sharpening should increase contrast at edge
    assert left_val < 1000 || right_val > 20000, "Edge should be sharpened"
  end

  def test_unsharp_mask_radius_edge_cases
    # Very small radius
    result1 = KDC::Sharpen.unsharp_mask(@image, radius: 0.1, amount: 1.0, threshold: 2)
    assert_instance_of Array, result1
    
    # Large radius
    result2 = KDC::Sharpen.unsharp_mask(@image, radius: 5.0, amount: 1.0, threshold: 2)
    assert_instance_of Array, result2
  end

  def test_unsharp_mask_amount_edge_cases
    # Negative amount (should sharpen in opposite direction?)
    result1 = KDC::Sharpen.unsharp_mask(@image, radius: 1.0, amount: -1.0, threshold: 2)
    assert_instance_of Array, result1
    
    # Large amount
    result2 = KDC::Sharpen.unsharp_mask(@image, radius: 1.0, amount: 5.0, threshold: 2)
    assert_instance_of Array, result2
  end

  def test_gaussian_blur_separable
    # Test that gaussian_blur produces reasonable output on image with edge
    image = Array.new(16) do |y|
      Array.new(16) do |x|
        val = x < 8 ? 1000 : 20000
        [val, val, val]
      end
    end
    
    blurred = KDC::Sharpen.gaussian_blur(image, 1.0)
    
    assert_instance_of Array, blurred
    assert_equal 16, blurred.length
    assert_equal 16, blurred[0].length
    
    # Check interior points (away from boundary clamping)
    # At x=3 (left side), should be near 1000
    # At x=12 (right side), should be near 20000
    # At x=7,8 (near edge), should be transitioning
    left_val = blurred[8][3][0]
    right_val = blurred[8][12][0]
    
    assert_in_delta 1000, left_val, 500, "Left side should be near 1000"
    assert_in_delta 20000, right_val, 500, "Right side should be near 20000"
    
    # Transition should be smoother (edge pixels intermediate)
    edge_left = blurred[8][7][0]
    edge_right = blurred[8][8][0]
    assert edge_left < edge_right, "Edge should show transition"
  end

  def test_gaussian_blur_preserves_uniform
    # Uniform image should remain uniform after blur
    uniform = Array.new(8) { Array.new(8) { [1000, 2000, 3000] } }
    blurred = KDC::Sharpen.gaussian_blur(uniform, 1.0)
    
    blurred.each do |row|
      row.each do |pixel|
        assert_in_delta 1000, pixel[0], 5
        assert_in_delta 2000, pixel[1], 5
        assert_in_delta 3000, pixel[2], 5
      end
    end
  end

  def test_unsharp_mask_different_channels_independent
    # Create image where only R channel has an edge
    channel_image = Array.new(8) do |y|
      Array.new(8) do |x|
        r = x < 4 ? 1000 : 20000
        [r, 10000, 10000]
      end
    end
    
    result = KDC::Sharpen.unsharp_mask(channel_image, radius: 1.0, amount: 1.0, threshold: 2)
    
    # Only R channel should be affected near edge
    # G and B should remain roughly constant (since no edge)
    g_vals = result.map { |row| row[3][1] }.uniq
    b_vals = result.map { |row| row[3][2] }.uniq
    
    # G and B should not vary much (uniform area)
    assert (g_vals.max - g_vals.min) < 100, "G channel should be stable"
    assert (b_vals.max - b_vals.min) < 100, "B channel should be stable"
  end

  def test_unsharp_mask_preserves_dimensions
    [4, 8, 16, 32, 64, 128].each do |size|
      img = Array.new(size) { Array.new(size) { [1000, 2000, 3000] } }
      result = KDC::Sharpen.unsharp_mask(img, radius: 1.0, amount: 1.0, threshold: 2)
      
      assert_equal size, result.length
      assert_equal size, result[0].length
    end
  end

  def test_unsharp_mask_non_square
    img = Array.new(10) { Array.new(20) { [1000, 2000, 3000] } }
    result = KDC::Sharpen.unsharp_mask(img, radius: 1.0, amount: 1.0, threshold: 2)
    
    assert_equal 10, result.length
    assert_equal 20, result[0].length
  end
end