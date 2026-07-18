# frozen_string_literal: true

module KDC
  module CameraData
    COLOR_MATRICES = {
      dc120: {
        # DNG ColorMatrix1 from dnglab's dc120.toml (XYZ to camera space)
        color_matrix1: [
          3.24045, -1.53713, -0.49853,
          -0.96926, 1.87601, 0.04155,
          0.05564, -0.20402, 1.05722
        ],
        calibration_illuminant1: 21, # D65
        black_level: 0,
        cfa_pattern: [1, 0, 2, 1], # GRBG
        cfa_repeat_pattern_dim: [2, 2],
        cfa_plane_color: [0, 1, 2] # R, G, B
      },
      dc50: {
        color_matrix1: [
          0.4124564, 0.3575761, 0.1804375,
          0.2126729, 0.7151522, 0.0721750,
          0.0193339, 0.1191920, 0.9503041
        ],
        calibration_illuminant1: 21,
        black_level: 0,
        cfa_pattern: [1, 0, 2, 1],
        cfa_repeat_pattern_dim: [2, 2],
        cfa_plane_color: [0, 1, 2]
      }
    }.freeze
  end
end
