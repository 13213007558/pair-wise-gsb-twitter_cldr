# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Collation

    # StringSearch performs locale-aware substring search using collation elements instead of raw code points.
    # That makes it possible to find substrings while ignoring accents and/or case, taking locale-specific
    # tailorings (contractions, expansions, reorderings) into account.
    #
    # The search is configured with a locale and a collation strength:
    #
    #   - :primary   - compares base letters only, ignoring accents and case (e.g. "resume" matches "r\u00e9sum\u00e9")
    #   - :secondary - compares base letters and accents, ignoring case (e.g. "Hello" matches "hello", but
    #                  "resume" does not match "r\u00e9sum\u00e9")
    #   - :tertiary  - compares everything, including case (default)
    #
    # Matching is performed on whole collation units (the collation elements produced by a single collation
    # step), not on the bytes of a compressed sort key, so matched positions can be mapped back to the
    # original string:
    #
    #   - a match may NOT begin or end inside an expansion (a single character that produces several
    #     collation elements, e.g. "\u00e6" in the root locale or "\u00e5" in Danish): the whole expanded
    #     character has to be covered by the match
    #   - contractions (several characters that produce a single collation element, e.g. "ch" in Slovak or
    #     "aa" in Danish) are matched atomically
    #   - characters that are ignorable at the given strength (e.g. combining accents at :primary strength
    #     or the soft hyphen) never break a match; trailing ignorable characters are absorbed into the
    #     match so the returned range covers the whole original cluster
    #
    # The result of a successful search is a half-open range of character offsets (not byte offsets) into
    # the original, non-normalized string, suitable for highlighting.
    #
    class StringSearch

      STRENGTH_LEVELS = { primary: 1, secondary: 2, tertiary: 3 }.freeze

      attr_reader :locale, :strength

      def initialize(locale = nil, options = {})
        @locale   = locale
        @strength = options.fetch(:strength, :tertiary)

        unless STRENGTH_LEVELS.key?(@strength)
          raise ArgumentError, "invalid collation strength #{@strength.inspect} "\
            "(valid strengths are #{STRENGTH_LEVELS.keys.join(', ')})"
        end

        @collator = Collator.new(locale)
        @level    = STRENGTH_LEVELS[@strength]
      end

      # Returns a half-open range of character offsets in +string+ covering the first occurrence of
      # +substring+, or nil if there is no match. An empty substring matches at the beginning of the
      # string (0...0), mirroring String#index.
      #
      def search(string, substring)
        return 0...0 if substring.empty?

        needle_items = significant_items(build_units(substring))
        return if needle_items.empty?

        haystack_units = build_units(string)

        find_match(haystack_units, significant_items(haystack_units), needle_items)
      end

      def match?(string, substring)
        !search(string, substring).nil?
      end

      private

      # A "unit" groups the collation elements produced by a single collation step (a character, an
      # expansion, or a contraction) together with the half-open range of characters in the original
      # string that produced them.
      #
      def build_units(string)
        code_points, tags = normalize_with_tags(string)

        @collator.collation_elements_with_positions(code_points).map do |elements, positions|
          originals = positions.map { |position| tags[position] }

          {
            tuples: elements.map { |element| weight_tuple(element) },
            first:  originals.min,
            last:   originals.max + 1
          }
        end
      end

      # Normalizes the string (NFD, exactly like the collator does) and tags every normalized code point
      # with the index of the character in the original string it came from. Canonical reordering only
      # permutes combining marks inside segments bounded by starters, so normalizing and reordering each
      # segment separately yields exactly the same code points as normalizing the whole string.
      #
      def normalize_with_tags(string)
        code_points = []
        tags        = []
        segment     = []

        flush_segment = lambda do
          segment.sort_by.with_index { |element, index| [element[2], index] }.each do |element|
            code_points << element[0]
            tags        << element[1]
          end

          segment.clear
        end

        string.each_char.with_index do |char, index|
          decomposed = TwitterCldr::Utils::CodePoints.from_string(TwitterCldr::Normalization.normalize(char))

          decomposed.each do |code_point|
            combining_class = combining_class_of(code_point)
            flush_segment.call if combining_class == 0
            segment << [code_point, index, combining_class]
          end
        end

        flush_segment.call

        [code_points, tags]
      end

      def combining_class_of(code_point)
        metadata = TwitterCldr::Shared::CodePoint.get(code_point)
        metadata ? metadata.combining_class.to_i : 0
      end

      # Flattens units into a list of [weight_tuple, unit_index, element_index] items, dropping collation
      # elements that are ignorable (have no weights) at the current strength.
      #
      def significant_items(units)
        items = []

        units.each_with_index do |unit, unit_index|
          unit[:tuples].each_with_index do |tuple, element_index|
            items << [tuple, unit_index, element_index] unless ignorable?(tuple)
          end
        end

        items
      end

      def find_match(haystack_units, haystack_items, needle_items)
        needle_size = needle_items.size

        (0..haystack_items.size - needle_size).each do |start|
          next unless (0...needle_size).all? { |i| haystack_items[start + i][0] == needle_items[i][0] }

          first = haystack_items[start]
          last  = haystack_items[start + needle_size - 1]

          # Matches may not begin or end inside an expansion: the first and the last matched collation
          # elements have to cover their units completely (ignorable elements do not count).
          next unless unit_start_covered?(haystack_units[first[1]], first[2])
          next unless unit_end_covered?(haystack_units[last[1]], last[2])

          # Absorb trailing characters that are ignorable at the current strength (e.g. a combining
          # accent that follows the matched letter) into the match.
          last_unit = last[1]
          last_unit += 1 while last_unit + 1 < haystack_units.size && ignorable_unit?(haystack_units[last_unit + 1])

          return haystack_units[first[1]][:first]...haystack_units[last_unit][:last]
        end

        nil
      end

      def weight_tuple(element)
        Array.new(@level) { |level| element[level] || 0 }
      end

      def ignorable?(tuple)
        tuple.all?(&:zero?)
      end

      def ignorable_unit?(unit)
        unit[:tuples].all? { |tuple| ignorable?(tuple) }
      end

      def unit_start_covered?(unit, element_index)
        unit[:tuples][0...element_index].all? { |tuple| ignorable?(tuple) }
      end

      def unit_end_covered?(unit, element_index)
        unit[:tuples][(element_index + 1)..-1].all? { |tuple| ignorable?(tuple) }
      end

    end

  end
end
