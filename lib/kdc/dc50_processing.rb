# frozen_string_literal: true

module KDC
  # DC50-specific color processing
  module DC50Processing
    # DC50 color matrix from KDC tag 0x9218 (embedded in file), libraw's rgb_cam.
    # 3x3 matrix: raw camera RGB -> sRGB (output_color=1).
    SRGB_MATRIX = [
      [ 1.812500, -0.336500, -0.476000 ],
      [ -0.435000,  1.852000, -0.417000 ],
      [ -0.676000, -1.393000,  3.069000 ]
    ].freeze

    # Apply DC50 color matrix (KDC tag 0x9218) with soft-clamp for negatives
    def self.apply_matrix(image)
      height = image.length
      width = image[0].length
      mat = SRGB_MATRIX

      # Pre-compute interpolated B-channel (demosaiced raw B) at G-pixels
      # Use 4 diagonal B-pixel neighbors in GRBG pattern
      b_at_g = {}
      height.times do |y|
        width.times do |x|
          next unless (x + y) % 2 == 1  # G-pixel in GRBG
          nb = 0; cnt = 0
          # Diagonal neighbors are B-pixels in GRBG
          [[-1,-1],[-1,1],[1,-1],[1,1]].each do |dx,dy|
            nx, ny = x+dx, y+dy
            if nx >= 0 && nx < width && ny >= 0 && ny < height
              _, _, b_raw = image[ny][nx]
              nb += b_raw
              cnt += 1
            end
          end
          b_at_g[[x,y]] = cnt > 0 ? nb / cnt : 0
        end
      end

      srgb = Array.new(height) do |y|
        Array.new(width) do |x|
          r, g, b = image[y][x]
          rs = mat[0][0] * r + mat[0][1] * g + mat[0][2] * b
          gs = mat[1][0] * r + mat[1][1] * g + mat[1][2] * b
          bs = mat[2][0] * r + mat[2][1] * g + mat[2][2] * b

          # At G-pixels where B goes negative, use interpolated B from diagonal B-pixels
          if bs < 0 && (x + y) % 2 == 1
            b_interp = b_at_g[[x,y]]
            # Apply only the B-coefficient (mat[2][2] = 3.069) since R,G contributions are unknown
            bs = mat[2][2] * b_interp
          end
          # Final safety clamp
          rs = [rs, 0].max
          gs = [gs, 0].max
          bs = [bs, 0].max
          [rs, gs, bs].map { |v| v.round }.map { |v| [v, 65535].min }
        end
      end

      srgb
    end

    # Apply DC50 auto-bright + gamma (for 8-bit output only; matrix already applied)
    def self.apply_gamma(image)
      height = image.length
      width = image[0].length

      # Step 2: histogram from matrix-multiplied values (libraw convert_to_rgb_loop)
      hist = Array.new(3) { Array.new(8192, 0) }
      height.times do |y|
        width.times do |x|
          image[y][x].each_with_index do |v, c|
            idx = v >> 3
            hist[c][idx] += 1 if idx < 8192
          end
        end
      end

      # Step 3: auto-brightness (libraw: per-channel t_white = max across channels, starting from 0)
      total_pixels = height * width
      thr = (total_pixels * 0.01).ceil
      t_white = [0, 0, 0]
      3.times do |c|
        accum = 0
        8191.downto(33) do |b|
          accum += hist[c][b]
          if accum > thr
            t_white[c] = b
            break
          end
        end
      end
      # Use single t_white = max across channels (libraw behavior in write_ppm_tiff)
      imax_val = t_white.max << 3
      imax = [imax_val] * 3

      # Step 4: libraw gamma_curve parameters (mode=0 -> compute g[2..5])
      pwr = 0.45
      ts  = 4.5
      bnd = [0.0, 1.0]
      48.times do
        g2 = (bnd[0] + bnd[1]) / 2.0
        c = ((g2 / ts) ** (-pwr) - 1) / pwr - 1.0 / g2
        c > -1 ? (bnd[1] = g2) : (bnd[0] = g2)
      end
      g2 = (bnd[0] + bnd[1]) / 2.0
      g3 = g2 / ts
      g4 = g2 * (1.0 / pwr - 1)

      # Step 5: apply gamma LUT (libraw mode=1 forward transform)
      pre = 65536.0
      out_max = 65535
      height.times do |y|
        width.times do |x|
          image[y][x] = image[y][x].map.with_index do |v, c|
            r = v.to_f / imax[c]
            if r < 1.0
              gv = r < g3 ? r * ts : r ** pwr * (1 + g4) - g4
              out = (gv * pre).round
              out > out_max ? out_max : out
            else
              out_max
            end
          end
        end
      end
      image
    end
  end
end
