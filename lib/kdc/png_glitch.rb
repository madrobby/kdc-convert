# frozen_string_literal: true

require "tempfile"
require "fileutils"
require "pnglitch"

module KDC
  # PNG glitch effect using the pnglitch gem.
  #
  # Supports two modes:
  #   1. Legacy: single intensity 0-100, all techniques randomly applied.
  #   2. Sequence: ordered list of `{type: :graft, intensity: 10}` entries.
  #
  # Sequence format is parsed from strings like "c10,d88,g12".
  module PngGlitch
    GLITCH_TYPES = {
      "g" => :graft, "graft" => :graft,
      "r" => :replace, "replace" => :replace,
      "t" => :transpose, "transpose" => :transpose,
      "d" => :defect, "defect" => :defect,
      "c" => :compressed, "compressed" => :compressed,
      "f" => :filters, "filters" => :filters,
    }.freeze

    class << self
      # Parse a glitch spec string.
      # Returns nil if no glitch, Integer for legacy mode, Array for sequence.
      def parse_glitch_spec(str)
        return 50 if str.nil? # bare --glitch

        return [[str.to_i, 0].max, 100].min if str.match?(/\A\d+\z/)

        parse_sequence(str)
      end

      # Apply PNG glitch effect.
      # +spec+ is an Integer (legacy) or Array of hashes (sequence).
      def apply(writer, output_path, spec)
        tmp_dir = File.join(File.dirname(__FILE__), "..", "..", "tmp")
        FileUtils.mkdir_p(tmp_dir)

        tempfile = Tempfile.new(["kdc_glitch", ".png"], tmp_dir)
        begin
          writer.write(tempfile.path)

          PNGlitch.open(tempfile.path) do |png|
            if spec.is_a?(Array)
              png.change_all_filters :paeth
              apply_sequence(png, spec)
            else
              apply_techniques(png, spec)
            end
            png.save(output_path)
          end
        ensure
          tempfile.close!
        end

        output_path
      end

      private

      def parse_sequence(str)
        pairs = str.split(",").map do |pair|
          pair = pair.strip
          next if pair.empty?

          m = pair.match(/\A([a-zA-Z]+)(\d+)\z/)
          next unless m

          type = GLITCH_TYPES[m[1].downcase]
          next unless type

          { type: type, intensity: m[2].to_i }
        end.compact

        pairs.empty? ? nil : pairs
      end

      # Apply techniques in order (sequence mode)
      def apply_sequence(png, sequence)
        sequence.each do |entry|
          send(entry[:type], png, entry[:intensity])
        end
      end

      # Each technique independently has a chance of occurring based on intensity
      def apply_techniques(png, intensity)
        srand
        chance = 0.5 + (intensity / 2) / 100.0

        png.change_all_filters :paeth

        graft(png, intensity)      if rand < chance
        replace(png, intensity)    if rand < chance
        transpose(png, intensity)  if rand < chance
        defect(png, intensity)     if rand < chance
        compressed(png, intensity) if rand < chance
      end

      # Apply wrong filter type to random scanlines (safe, always valid PNG)
      def graft(png, intensity)
        Util.log(" ⇢ graft @#{intensity}")
        total = png.height
        count = (total * intensity / 100.0).round
        count = [count, 1].max

        indices = (0...total).to_a.sample(count)
        png.each_scanline do |scanline|
          scanline.graft(rand(5)) if indices.include?(scanline.index)
        end
      end

      # Randomly overwrite bytes in filtered data
      def replace(png, intensity)
        Util.log(" ⇢ replace @#{intensity}")
        range = (intensity / 100.0 * 50).round
        range = [range, 1].max
        png.glitch do |data|
          range.times { data[rand(data.size)] = "x" }
          data
        end
      end

      # Rearrange chunks of filtered data
      def transpose(png, intensity)
        Util.log(" ⇢ transpose @#{intensity}")

        png.glitch do |data|
          x = data.size / 4
          data[0, x] + data[x * 2, x] + data[x * 1, x] + data[x * 3..-1]
          data
        end
      end

      # Randomly delete bytes in filtered data
      def defect(png, intensity)
        Util.log(" ⇢ defect @#{intensity}")

        range = [intensity, 1].max
        png.glitch do |data|
          range.times { data[rand(data.size)] = "" }
          data
        end
      end

      # Glitch the compressed data (most destructive)
      def compressed(png, intensity)
        Util.log(" ⇢ compressed @#{intensity}")

        range = [intensity, 1].max
        png.glitch_after_compress do |data|
          range.times { data[rand(data.size)] = "x" }
          data
        end
      end

      # Disabled technique — randomize scanline filter types
      def filters(png, intensity)
        Util.log(" ⇢ filters @#{intensity}")

        chance = intensity / 100.0
        png.each_scanline do |scanline|
          scanline.change_filter(rand(4).round) if rand < chance
        end
      end
    end
  end
end
