# frozen_string_literal: true

module KDC
  class DC50Decoder
    RAW_WIDTH  = 768
    RAW_HEIGHT = 512

    SRC = [
       1, 1,   2, 3,   3, 4,   4, 2,   5, 7,   6, 5,   7, 6,   7, 8,   1, 0,
       2, 1,   3, 3,   4, 4,   5, 2,   6, 7,   7, 6,   8, 5,   8, 8,   2, 1,
       2, 3,   3, 0,   3, 2,   3, 4,   4, 6,   5, 5,   6, 7,   6, 8,   2, 0,
       2, 1,   2, 3,   3, 2,   4, 4,   5, 6,   6, 7,   7, 5,   7, 8,   2, 1,
       2, 4,   3, 0,   3, 2,   3, 3,   4, 7,   5, 5,   6, 6,   6, 8,   2, 3,
       3, 1,   3, 2,   3, 4,   3, 5,   3, 6,   4, 7,   5, 0,   5, 8,   2, 3,
       2, 6,   3, 0,   3, 1,   4, 4,   4, 5,   4, 7,   5, 2,   5, 8,   2, 4,
       2, 7,   3, 3,   3, 6,   4, 1,   4, 2,   4, 5,   5, 0,   5, 8,   2, 6,
       3, 1,   3, 3,   3, 5,   3, 7,   3, 8,   4, 0,   5, 2,   5, 4,   2, 0,
       2, 1,   3, 2,   3, 3,   4, 4,   4, 5,   5, 6,   5, 7,   4, 8,   1, 0,
       2, 2,   2, -2,  1, -3,  1, 3,   2, -17, 2, -5,  2, 5,   2, 17,  2, -7,
       2, 2,   2, 9,   2, 18,  2, -18, 2, -9,  2, -2,  2, 7,   2, -28, 2, 28,
       3, -49, 3, -9,  3, 9,   4, 49,  5, -79, 5, 79,  2, -1,  2, 13,  2, 26,
       3, 39,  4, -16, 5, 55,  6, -37, 6, 76,  2, -26, 2, -13, 2, 1,   3, -39,
       4, 16,  5, -55, 6, -76, 6, 37
    ].freeze

    PT = [0, 0, 1280, 1344, 2320, 3616, 3328, 8000, 4095, 16383, 65535, 16383].freeze

    def initialize(file_path, data_offset:, data_size:, remove_stuck_pixels: true)
      @file_path = file_path
      @data_offset = data_offset
      @data_size = data_size
      @remove_stuck_pixels = remove_stuck_pixels
      @raw_image = nil
    end

    def decode
      data = File.open(@file_path, "rb") do |io|
        io.pos = @data_offset
        io.read(@data_size)
      end

      # build tone curve
      curve = Array.new(16384, 0)
      (2...12).step(2) do |i|
        pt_lo = PT[i - 2]
        pt_hi = PT[i]
        y_lo  = PT[i - 1]
        y_hi  = PT[i + 1]
        range = pt_hi - pt_lo
        (pt_lo..pt_hi).each do |cc|
          curve[cc] = ((cc - pt_lo).to_f / range * (y_hi - y_lo) + y_lo + 0.5).to_i
        end
      end

      # build huffman table (19 * 256 entries)
      huff = Array.new(19 * 256, 0)
      s = 0
      i = 0
      while i < SRC.length
        shift = SRC[i]
        hi = SRC[i] & 0xFF
        lo = SRC[i + 1] & 0xFF
        val = (hi << 8) | lo
        cnt = 256 >> shift
        cnt.times do
          huff[s] = val
          s += 1
        end
        i += 2
      end
      # tree 18 – simple fixed-length table
      ss = 3  # kodak_cbpp != 243
      (0..255).each do |cc|
        huff[18 * 256 + cc] = ((8 - ss) << 8) | ((cc >> ss) << ss) | (1 << (ss - 1))
      end

      # 3-channel buffer, each containing 3 rows of 386 shorts
      buf = Array.new(3) { Array.new(3) { Array.new(386, 2048) } }
      last = [16, 16, 16]

      @raw_image = Array.new(RAW_HEIGHT * RAW_WIDTH, 0)
      io = BitReader.new(data)
      io.reset_bits

      row = 0
      while row < RAW_HEIGHT
        # read 6-bit multipliers for each channel
        mul = [io.getbits(6), io.getbits(6), io.getbits(6)]
        mul = mul.map { |m| m == 0 ? 1 : m }  # avoid division by zero (valid in libraw)

        3.times do |c|
          vv = ((0x1000000 / last[c] + 0x7ff) >> 12) * mul[c]
          ss = vv > 65564 ? 10 : 12
          xx = ~((~0 & 0xFFFFFFFF) << (ss - 1)) & 0xFFFFFFFF
          vv <<= 12 - ss

          # scale the 2D buffer: buf[c][0..2][0..385]
          buf[c].each_with_index do |row_buf, _ri|
            row_buf.each_with_index do |val, j|
              scaled = (val * vv + xx) >> ss
              scaled = [scaled, 0x7FFFFFFF].min
              row_buf[j] = scaled & 0xFFFF
            end
          end

          last[c] = mul[c]

          rmax = c == 0 ? 1 : 0
          (0..rmax).each do |r|
            half_w = RAW_WIDTH / 2
            buf[c][1][half_w] = mul[c] << 7
            buf[c][2][half_w] = mul[c] << 7

            tree = 1
            col = half_w
            while col > 0
              tok = io.radc_token(huff, tree)
              tree = tok  # signed char

              if tree != 0
                col -= 2
                next if col < 0

                if tree == 8
                  for y in 1..2
                    for x in [col + 1, col]
                      buf[c][y][x] = (io.radc_token(huff, 18) & 0xFF) * mul[c]
                    end
                  end
                else
                  for y in 1..2
                    for x in [col + 1, col]
                      diff = io.radc_token(huff, tree + 10) * 16
                      pred = if c != 0
                                (buf[c][y - 1][x] + buf[c][y][x + 1]) / 2
                              else
                                (buf[c][y - 1][x + 1] + 2 * buf[c][y - 1][x] + buf[c][y][x + 1]) / 4
                              end
                      buf[c][y][x] = diff + pred
                    end
                  end
                end
              else
                # run-length
                loop do
                  nreps = col > 2 ? io.radc_token(huff, 9) + 1 : 1
                  rep = 0
                  while rep < 8 && rep < nreps && col > 0
                    col -= 2
                    if col >= 0
                      for y in 1..2
                        for x in [col + 1, col]
                          pred = if c != 0
                                    (buf[c][y - 1][x] + buf[c][y][x + 1]) / 2
                                  else
                                    (buf[c][y - 1][x + 1] + 2 * buf[c][y - 1][x] + buf[c][y][x + 1]) / 4
                                  end
                          buf[c][y][x] = pred
                        end
                      end
                    end
                    if (rep & 1) != 0
                      step = io.radc_token(huff, 10) << 4
                      for y in 1..2
                        for x in [col + 1, col]
                          buf[c][y][x] += step
                        end
                      end
                    end
                    rep += 1
                  end
                  break unless nreps == 9
                end
              end
            end

            # write decoded values to raw_image
            (0..1).each do |y|
              (0...half_w).each do |xi|
                vv2 = (buf[c][y + 1][xi] << 4) / mul[c]
                vv2 = 0 if vv2 < 0
                if c != 0
                  @raw_image[(row + y * 2 + c - 1) * RAW_WIDTH + (xi * 2 + 2 - c)] = vv2
                else
                  @raw_image[(row + r * 2 + y) * RAW_WIDTH + (xi * 2 + y)] = vv2
                end
              end
            end

            # memcpy buf[c][0] + !c, buf[c][2], sizeof buf[c][0] - 2 * !c
            offset = c == 0 ? 1 : 0
            copy_len = 386 - offset
            copy_len.times do |ti|
              buf[c][0][ti + offset] = buf[c][2][ti]
            end
          end
        end

        # interpolate missing pixels
        (row...[row + 4, RAW_HEIGHT].min).each do |y|
          RAW_WIDTH.times do |xi|
            if ((xi + y) & 1) != 0
              left  = xi > 0 ? xi - 1 : xi + 1
              right = xi + 1 < RAW_WIDTH ? xi + 1 : xi - 1
              vv2 = (@raw_image[y * RAW_WIDTH + xi] - 2048) * 2 +
                    (@raw_image[y * RAW_WIDTH + left] + @raw_image[y * RAW_WIDTH + right]) / 2
              vv2 = 0 if vv2 < 0
              @raw_image[y * RAW_WIDTH + xi] = vv2
            end
          end
        end

        row += 4
      end

      # apply curve
      total_pixels = RAW_HEIGHT * RAW_WIDTH
      total_pixels.times do |i|
        v = @raw_image[i]
        @raw_image[i] = v < curve.length ? curve[v] : curve.last
      end

      # remove stuck pixels if needed
      remove_stuck_pixels_bayer if @remove_stuck_pixels

      @raw_image
    end

    private

    def remove_stuck_pixels_bayer
      height = RAW_HEIGHT
      width = RAW_WIDTH
      return if height <= 4 || width <= 4

      result = @raw_image.dup
      height.times do |y|
        width.times do |x|
          neighbors = []
          [[0, 2], [0, -2], [2, 0], [-2, 0]].each do |dy, dx|
            ny = y + dy
            nx = x + dx
            next unless ny >= 0 && ny < height && nx >= 0 && nx < width
            neighbors << @raw_image[ny * width + nx]
          end
          next if neighbors.empty?

          val = @raw_image[y * width + x]
          all = [val] + neighbors
          mean = all.sum.to_f / all.length
          range = all.max - all.min

          next if range <= 15
          next if (val - mean).abs <= 0.75 * range
          next if (val - mean).abs < 200

          sorted = neighbors.sort
          n = sorted.length
          median = n.odd? ? sorted[n / 2] : ((sorted[n / 2 - 1] + sorted[n / 2]) / 2)
          result[y * width + x] = median
        end
      end

      @raw_image = result
    end

    # bitstream reader matching LibRaw getbithuff / getbits
    class BitReader
      def initialize(data)
        @data = data
        @bitbuf = 0
        @vbits = 0
        @reset = false
        @pos = 0
      end

      def reset_bits
        @bitbuf = 0
        @vbits = 0
        @reset = false
      end

      def getbits(n)
        getbithuff(n, nil)
      end

      def getbithuff(nbits, huff)
        return 0 if nbits > 25

        if nbits < 0
          @bitbuf = 0
          @vbits = 0
          @reset = false
          @pos = 0
          return 0
        end
        return 0 if nbits == 0 || @vbits < 0

        while !@reset && @vbits < nbits && @pos < @data.bytesize
          c = @data.getbyte(@pos)
          @pos += 1
          break if c.nil?
          @bitbuf = ((@bitbuf << 8) | c) & 0xFFFFFFFF
          @vbits += 8
        end

        c = @vbits == 0 ? 0 : ((@bitbuf << (32 - @vbits)) & 0xFFFFFFFF) >> (32 - nbits)

        if huff
          @vbits -= (huff[c] >> 8)
          c = huff[c] & 0xFF
        else
          @vbits -= nbits
        end

        c & 0xFF
      end

      def radc_token(huff, tree)
        raw = getbithuff(8, huff[tree * 256, 256])
        raw >= 128 ? raw - 256 : raw
      end
    end
  end
end
