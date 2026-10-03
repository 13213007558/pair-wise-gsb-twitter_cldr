# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Security
    # UTS #39 Section 4 (Confusable Detection) skeleton computation.
    #
    # skeleton(str) = NFD, replace each confusable character (or sequence)
    # with its prototype from the confusables table, then NFD again.
    #
    # Two strings are confusable if and only if their skeletons are equal.
    # Skeletons are case-preserving per the specification; pass
    # case_sensitive: false to additionally apply full Unicode case
    # folding before computing the skeleton (a twitter-cldr extension that
    # is useful for case-insensitive account name comparison).
    class Confusables
      RESOURCE_PATH = %i[shared security confusables].freeze

      class << self
        def skeleton(string, case_sensitive: true)
          string = TwitterCldr::Shared::Casefolder.full_casefold(string) unless case_sensitive
          decomposed = TwitterCldr::Normalization.normalize(string.to_s, using: :nfd)
          TwitterCldr::Normalization.normalize(apply_mappings(decomposed), using: :nfd)
        end

        def confusable?(first, second, case_sensitive: true)
          skeleton(first, case_sensitive: case_sensitive) ==
            skeleton(second, case_sensitive: case_sensitive)
        end

        # Maps source character sequences (as strings) to their
        # replacement ("prototype") strings.
        def mapping
          @mapping ||= load_mapping
        end

        private

        def apply_mappings(decomposed)
          chars = decomposed.chars
          result = +''
          index = 0

          while index < chars.length
            replacement, length = longest_match_at(chars, index)

            if replacement
              result << replacement
              index += length
            else
              result << chars[index]
              index += 1
            end
          end

          result
        end

        def longest_match_at(chars, index)
          length = [max_source_length, chars.length - index].min

          while length > 0
            candidate = chars[index, length].join
            return [mapping[candidate], length] if mapping.include?(candidate)
            length -= 1
          end

          nil
        end

        def max_source_length
          @max_source_length ||= mapping.keys.map(&:length).max || 1
        end

        def load_mapping
          TwitterCldr.get_resource(*RESOURCE_PATH).each_with_object({}) do |(hex_sequence, target), ret|
            source = hex_sequence.to_s.split(' ').map { |hex| hex.to_i(16) }.pack('U*')
            ret[source] = target
          end
        end
      end
    end
  end
end
