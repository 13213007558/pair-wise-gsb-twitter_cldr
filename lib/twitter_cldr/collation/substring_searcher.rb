# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Collation

    # SubstringSearcher performs locale-aware substring search using collation elements instead of raw
    # code points. That makes it possible to find matches that are canonically or locally equivalent to
    # the needle (e.g. accented characters, contractions like Czech "ch" or Danish "aa") while reporting
    # match boundaries as half-open character ranges in the *original*, not normalized, string.
    #
    # The search is configured with a collation strength:
    #
    #   :primary   - base letters only (accents and case are ignored, "resume" matches "r\u00E9sum\u00E9")
    #   :secondary - base letters and accents (case is ignored, "resume" does not match "r\u00E9sum\u00E9")
    #   :tertiary  - base letters, accents and case (only canonically equivalent strings match)
    #
    # Matching rules (kept deliberately consistent):
    #
    #   * A match IS allowed to cover only a part of an expansion (one character that produces several
    #     collation elements, e.g. "\u00E6" which collates like "ae"). In that case the returned range is
    #     extended to the boundaries of the whole character, so searching for "a" in "\u00E6" returns 0...1.
    #   * A match is NOT allowed to start or end inside a contraction (several characters that produce a
    #     single collation element, e.g. "ch" in Czech), because the contraction compares as a single unit.
    #   * Characters that are ignorable at the given strength (e.g. combining accents at :primary strength)
    #     do not take part in the comparison. Ignorable characters between matched characters are included
    #     in the match, and the end of the match is extended over any immediately following ignorable
    #     characters, so the returned range never cuts a combining mark off its base character.
    #   * Returned ranges never split a combining character sequence: a range boundary that falls inside a
    #     segment of the normalized text that came from a single grapheme-like unit of the original string
    #     is moved to that unit's boundary.
    #
    # Ranges are returned as half-open character ranges (e.g. 0...6) suitable for highlighting the matched
    # substring of the original string via String#[], i.e. +string[range]+ returns the matched text.
    #
    class SubstringSearcher

      STRENGTH_LEVELS = {
        primary:   1,
        secondary: 2,
        tertiary:  3
      }.freeze

      DEFAULT_STRENGTH = :tertiary

      attr_reader :locale, :strength

      def initialize(options = {})
        @locale   = options[:locale] && TwitterCldr.convert_locale(options[:locale])
        @strength = options.fetch(:strength, DEFAULT_STRENGTH)

        unless STRENGTH_LEVELS.key?(@strength)
          raise ArgumentError, "invalid strength #{@strength.inspect} " \
            "(valid strengths are #{STRENGTH_LEVELS.keys.map(&:inspect).join(', ')})"
        end

        @collator = Collator.new(@locale)
        @level    = STRENGTH_LEVELS[@strength]
      end

      # Returns a half-open character range of the first match of +needle+ in +haystack+, or nil if the
      # needle was not found (or has no significant collation weight at the configured strength).
      #
      def search(haystack, needle)
        find_all(haystack, needle).first
      end

      # Returns an array of half-open character ranges for all non-overlapping matches of +needle+ in
      # +haystack+ (in order of appearance).
      #
      def find_all(haystack, needle)
        needle_weights = significant_weights(needle)
        return [] if needle_weights.empty?

        entries, char_starts, char_ends = haystack_entries(haystack)
        significant = entries.reject { |entry| zero_weights?(entry[:weights]) }

        ranges = []
        idx = 0
        last_start = significant.size - needle_weights.size

        while idx <= last_start
          if weights_match?(significant, idx, needle_weights)
            ranges << build_range(significant[idx], significant[idx + needle_weights.size - 1], entries, char_starts, char_ends)
            idx += needle_weights.size
          else
            idx += 1
          end
        end

        ranges
      end

      private

      # Builds an array of entries (one per collation element of the haystack) along with two arrays that
      # map a normalized code point index to the half-open character range of the original string that
      # produced the surrounding normalization segment.
      #
      def haystack_entries(haystack)
        normalized, char_starts, char_ends = normalize_with_char_map(haystack)

        entries = @collator.get_collation_elements_with_positions(normalized).map.with_index do |(collation_element, positions), element_idx|
          {
            weights:   level_weights(collation_element),
            positions: positions,
            index:     element_idx
          }
        end

        [entries, char_starts, char_ends]
      end

      def significant_weights(string)
        @collator.get_collation_elements(string).map { |collation_element| level_weights(collation_element) }
          .reject { |weights| zero_weights?(weights) }
      end

      def level_weights(collation_element)
        collation_element.first(@level).map { |weight| weight || 0 }
      end

      def zero_weights?(weights)
        weights.all?(&:zero?)
      end

      def weights_match?(significant, offset, needle_weights)
        needle_weights.each_with_index.all? do |weights, idx|
          significant[offset + idx][:weights] == weights
        end
      end

      # Maps a match (given by its first and last significant entries) back to a half-open character range
      # in the original string. The end of the match is extended over immediately following elements that
      # are ignorable at the configured strength.
      #
      def build_range(first_entry, last_entry, entries, char_starts, char_ends)
        last_index = last_entry[:index]
        last_index += 1 while entries[last_index + 1] && zero_weights?(entries[last_index + 1][:weights])

        start_position = first_entry[:positions].first
        end_position   = entries[first_entry[:index]..last_index].map { |entry| entry[:positions].last }.max

        char_starts[start_position]...char_ends[end_position]
      end

      # Normalizes the string (NFD, like the collator does) and builds two arrays that map every index of
      # the normalized code points sequence to the half-open character range of the original string that
      # produced the surrounding segment. Normalization is performed segment by segment (a segment starts
      # at every starter, i.e. a code point with a zero combining class): canonical reordering never moves
      # code points across starter boundaries, so concatenating per-segment normalizations yields exactly
      # the same normalized text as normalizing the whole string at once.
      #
      def normalize_with_char_map(string)
        normalized_code_points = []
        char_starts = []
        char_ends   = []

        each_segment(string) do |char_start, char_end, segment|
          segment_code_points = TwitterCldr::Utils::CodePoints.from_string(
            TwitterCldr::Normalization.normalize(segment)
          )

          segment_code_points.each do
            char_starts << char_start
            char_ends   << char_end
          end

          normalized_code_points.concat(segment_code_points)
        end

        [normalized_code_points, char_starts, char_ends]
      end

      # Yields [char_start, char_end, segment] for every maximal combining character sequence of the
      # string (a starter plus all the non-starters that follow it; leading non-starters form their own
      # segment).
      #
      def each_segment(string)
        segment_start = 0

        string.each_char.with_index do |char, char_index|
          next if char_index == 0 || !starter?(char)

          yield(segment_start, char_index, string[segment_start...char_index])
          segment_start = char_index
        end

        yield(segment_start, string.length, string[segment_start..-1]) if segment_start < string.length
      end

      def starter?(char)
        metadata = TwitterCldr::Shared::CodePoint.get(TwitterCldr::Utils::CodePoints.from_string(char).first)
        !metadata || metadata.combining_class.to_i == 0
      end

    end

  end
end
