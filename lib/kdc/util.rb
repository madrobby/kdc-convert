# frozen_string_literal: true

module KDC
  module Util
    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.human_size(bytes)
      if bytes < 1024
        "#{bytes} B"
      elsif bytes < 1024 * 1024
        "%.1f KB" % (bytes / 1024.0)
      elsif bytes < 1024 * 1024 * 1024
        "%.1f MB" % (bytes / (1024.0 * 1024.0))
      else
        "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))
      end
    end

    def self.format_duration(seconds)
      "%.3fs" % seconds
    end

    def self.format_resolution(width, height)
      "#{width}×#{height}"
    end
  end
end
