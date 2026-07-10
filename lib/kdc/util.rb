# frozen_string_literal: true

require "rainbow"

module KDC
  module Util
    def self.verbose?
      @verbose == true
    end

    def self.verbose=(val)
      @verbose = val
    end

    def self.log(message)
      puts(message) if verbose?
    end

    def self.success(message)
      puts(Rainbow(message).green) if verbose?
    end

    def self.warn(message)
      $stderr.puts(Rainbow(message).yellow)
    end

    def self.error(message)
      $stderr.puts(Rainbow(message).red)
    end

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
      "#{width}\u00d7#{height}"
    end

    def self.visible_length(str)
      str.to_s.gsub(/\e\[[0-9;]*m/, "").length
    end

    def self.pad_to_visible(str, width)
      str + " " * ([width - visible_length(str), 0].max)
    end
  end
end
