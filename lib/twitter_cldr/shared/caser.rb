# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Shared
    class Caser
      REGEX = /./

      class << self
        def upcase(string)
          string.gsub(REGEX, uppercasing_hash)
        end

        def downcase(string)
          string.gsub(REGEX, lowercasing_hash)
        end

        # toTitlecase(X): Find the word boundaries in X according
        # to Unicode Standard Annex #29, "Unicode Text Segmentation."
        # For each word boundary, find the first cased character F
        # following the word boundary. If F exists, map F to
        # Titlecase_Mapping(F); then map all characters C between F
        # and the following word boundary to Lowercase_Mapping(C).
        def titlecase(string)
          string.dup.tap do |result|
            word_iterator.each_word(result) do |_, *boundary_pair|
              if cased_pos = first_cased(string, *boundary_pair)
                result[cased_pos] = titlecasing_hash[result[cased_pos]]

                (cased_pos + 1).upto(boundary_pair.last - 1) do |pos|
                  result[pos] = lowercasing_hash[result[pos]]
                end
              end
            end
          end
        end

        # Full Unicode case mapping. Unlike the simple casing methods above,
        # these methods apply the full (potentially multi-character) mappings
        # from SpecialCasing.txt as well as the locale-specific (Turkish,
        # Azeri, Lithuanian) and context-sensitive (e.g. Greek final sigma)
        # conditional mappings.
        def full_upcase(string, locale = nil)
          full_case_map(string, locale, :upper)
        end

        def full_downcase(string, locale = nil)
          full_case_map(string, locale, :lower)
        end

        def full_titlecase(string, locale = nil)
          directions = {}

          word_iterator.each_word(string) do |_, *boundary_pair|
            if cased_pos = first_cased(string, *boundary_pair)
              directions[cased_pos] = :title

              (cased_pos + 1).upto(boundary_pair.last - 1) do |pos|
                directions[pos] = :lower
              end
            end
          end

          language = language_code_for(locale)
          code_points = string.unpack('U*')
          result = +''

          string.each_char.with_index do |char, pos|
            direction = directions[pos]

            result << if direction
              full_mapping_for(code_points, pos, language, direction)
            else
              char
            end
          end

          result
        end

        private

        def full_case_map(string, locale, direction)
          language = language_code_for(locale)
          code_points = string.unpack('U*')
          result = +''

          code_points.each_index do |pos|
            result << full_mapping_for(code_points, pos, language, direction)
          end

          result
        end

        # Context is always evaluated against the original code points so
        # that characters produced by multi-character mappings are never
        # mistaken for the original context.
        def full_mapping_for(code_points, pos, language, direction)
          code_point = code_points[pos]

          if mapping = conditional_mapping_for(code_point, code_points, pos, language)
            return mapping[direction].pack('U*')
          end

          if mapping = unconditional_full_mappings[code_point]
            return mapping[direction].pack('U*')
          end

          simple_mapping_for(code_point, direction)
        end

        def conditional_mapping_for(code_point, code_points, pos, language)
          return unless conditional_full_mappings.include?(code_point)

          conditional_full_mappings[code_point].find do |mapping|
            conditions_met?(mapping[:conditions], language, code_points, pos)
          end
        end

        def conditions_met?(conditions, language, code_points, pos)
          conditions.all? do |condition|
            case condition
            when 'tr', 'az', 'lt'
              language == condition
            when 'Final_Sigma'
              final_sigma?(code_points, pos)
            when 'More_Above'
              more_above?(code_points, pos)
            when 'After_Soft_Dotted'
              after_soft_dotted?(code_points, pos)
            when 'After_I'
              after_i?(code_points, pos)
            when 'Not_Before_Dot'
              !followed_by_dot_above?(code_points, pos)
            else
              false
            end
          end
        end

        def final_sigma?(code_points, pos)
          preceded_by_cased?(code_points, pos) &&
            !followed_by_cased?(code_points, pos)
        end

        def preceded_by_cased?(code_points, pos)
          (pos - 1).downto(0) do |i|
            code_point = code_points[i]
            next if case_ignorable?(code_point)
            return cased_code_point?(code_point)
          end

          false
        end

        def followed_by_cased?(code_points, pos)
          (pos + 1).upto(code_points.size - 1) do |i|
            code_point = code_points[i]
            next if case_ignorable?(code_point)
            return cased_code_point?(code_point)
          end

          false
        end

        def more_above?(code_points, pos)
          (pos + 1).upto(code_points.size - 1) do |i|
            combining_class = canonical_combining_class(code_points[i])
            return false if combining_class == 0
            return true if combining_class == 230
          end

          false
        end

        def after_soft_dotted?(code_points, pos)
          after_base_code_point?(code_points, pos) do |code_point|
            soft_dotted?(code_point)
          end
        end

        def after_i?(code_points, pos)
          after_base_code_point?(code_points, pos) do |code_point|
            code_point == 0x49 # LATIN CAPITAL LETTER I
          end
        end

        # Finds the last preceding character with a combining class of zero,
        # failing if an intervening character has combining class 230 (Above).
        def after_base_code_point?(code_points, pos)
          (pos - 1).downto(0) do |i|
            code_point = code_points[i]
            combining_class = canonical_combining_class(code_point)
            return false if combining_class == 230
            next unless combining_class == 0
            return yield(code_point)
          end

          false
        end

        def followed_by_dot_above?(code_points, pos)
          (pos + 1).upto(code_points.size - 1) do |i|
            code_point = code_points[i]
            return true if code_point == 0x0307 # COMBINING DOT ABOVE
            return false unless case_ignorable?(code_point)
          end

          false
        end

        def simple_mapping_for(code_point, direction)
          char = code_point.chr(Encoding::UTF_8)

          case direction
          when :upper then uppercasing_hash[char]
          when :lower then lowercasing_hash[char]
          when :title then titlecasing_hash[char]
          end
        end

        def language_code_for(locale)
          return unless locale

          language = locale.to_s.split(/[-_]/).first
          language && language.downcase
        end

        def cased_code_point?(code_point)
          cased_property.include?(code_point)
        end

        def case_ignorable?(code_point)
          case_ignorable_property.include?(code_point)
        end

        def soft_dotted?(code_point)
          soft_dotted_property.include?(code_point)
        end

        def canonical_combining_class(code_point)
          value = CodePoint.properties_for_code_point(
            code_point
          ).canonical_combining_class

          value.is_a?(Enumerable) ? value.first.to_i : 0
        end

        def cased_property
          @cased_property ||= CodePoint.code_points_for_property('Cased')
        end

        def case_ignorable_property
          @case_ignorable_property ||=
            CodePoint.code_points_for_property('Case_Ignorable')
        end

        def soft_dotted_property
          @soft_dotted_property ||=
            CodePoint.code_points_for_property('Soft_Dotted')
        end

        def unconditional_full_mappings
          @unconditional_full_mappings ||=
            special_casing_data.each_with_object({}) do |mapping, result|
              result[mapping[:source]] = mapping if mapping[:conditions].empty?
            end
        end

        def conditional_full_mappings
          @conditional_full_mappings ||=
            special_casing_data.each_with_object(
              Hash.new { |hash, key| hash[key] = [] }
            ) do |mapping, result|
              unless mapping[:conditions].empty?
                result[mapping[:source]] << mapping
              end
            end
        end

        def special_casing_data
          @special_casing_data ||=
            TwitterCldr.get_resource('unicode_data', 'special_casing')
        end

        def first_cased(string, start_pos, end_pos)
          end_pos = string.length - 1 if end_pos >= string.length

          start_pos.upto(end_pos) do |pos|
            return pos if cased?(string[pos])
          end
        end

        def word_iterator
          @word_iterator ||= Segmentation::BreakIterator.new(:en)
        end

        def cased?(char)
          props = CodePoint.properties_for_code_point(char.ord)
          props.general_category.include?('Lt') ||
            props.uppercase || props.lowercase
        end

        def uppercasing_hash
          @uppercasing_hash ||= Hash.new do |hash, key|
            memoize_value(:simple_uppercase_map, hash, key)
          end
        end

        def lowercasing_hash
          @lowercasing_hash ||= Hash.new do |hash, key|
            memoize_value(:simple_lowercase_map, hash, key)
          end
        end

        def titlecasing_hash
          @titlecasing_hash ||= Hash.new do |hash, key|
            memoize_value(:simple_titlecase_map, hash, key)
          end
        end

        def memoize_value(field, hash, key)
          cp = TwitterCldr::Shared::CodePoint.get(key.ord)
          mapped_result = cp && cp.send(field)
          hash[key] = mapped_result ? mapped_result : key
        end
      end
    end
  end
end
