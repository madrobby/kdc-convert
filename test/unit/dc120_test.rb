# frozen_string_literal: true

require_relative "../test_helper"

class DC120Test < Minitest::Test
  include TestHelper

  def test_decode_returns_bayer_array
    decoder = KDC::DC120Decoder.new(kdc_path("DC120-flash-raw.kdc"), compressed: false, remove_stuck_pixels: false)
    bayer = decoder.decode

    assert_instance_of Array, bayer
    assert_equal 976, bayer.length
    assert_equal 848, bayer[0].length
  end

  def test_bayer_values_in_range
    decoder = KDC::DC120Decoder.new(kdc_path("DC120-flash-raw.kdc"), compressed: false, remove_stuck_pixels: false)
    bayer = decoder.decode
    
    min_val = bayer.flatten.min
    max_val = bayer.flatten.max
    
    assert min_val >= 0, "Min value #{min_val} should be >= 0"
    assert max_val <= 65535, "Max value #{max_val} should be <= 65535"
  end

  def test_byte_swap
    # Create test data: [0x01, 0x02, 0x03, 0x04]
    data = [1, 2, 3, 4].pack("C*")
    swapped = KDC::DC120Decoder.new(nil).send(:byte_swap, data)
    
    assert_equal [2, 1, 4, 3], swapped.bytes
  end

  def test_expand_to_bayer_grbg_pattern
    # Create a simple 2x2 RGB image (enough for one 2x2 Bayer block)
    mock_image = MockImage.new(2, 2)
    
    decoder = KDC::DC120Decoder.new(nil)
    bayer = decoder.send(:expand_to_bayer, mock_image)
    
    # Should produce RAW_HEIGHT x RAW_WIDTH Bayer array
    assert_equal KDC::DC120Decoder::RAW_HEIGHT, bayer.length
    assert_equal KDC::DC120Decoder::RAW_WIDTH, bayer[0].length
  end
  
  class MockImage
    attr_reader :width, :height
    
    def initialize(width, height)
      @width = width
      @height = height
      @pixels = {}
      
      # Pre-populate with some test data
      height.times do |y|
        width.times do |x|
          @pixels[[x, y]] = OpenStruct.new(r: x * 10, g: y * 10, b: (x + y) * 10)
        end
      end
    end
    
    def [](x, y)
      @pixels[[x, y]]
    end
  end
end
