# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Security
    # UTS #39 Section 3.1 (Restriction Levels) detection.
    #
    # Script classification follows UTS #39 Tables 5a, 5b and 7 as of
    # Unicode 16.0.0 (the Unicode version of the bundled property data):
    #
    # * Recommended scripts get the least restrictive treatment.
    # * Aspirational scripts are allowed in moderately/minimally
    #   restrictive identifiers.
    # * Limited Use scripts (and everything else, i.e. Exclusion scripts)
    #   make an identifier :unrestricted.
    class RestrictionLevel
      LEVELS = %i[
        ascii
        single_script
        highly_restrictive
        moderately_restrictive
        minimally_restrictive
        unrestricted
      ].freeze

      # UTS #39 Table 5a (Recommended Scripts).
      RECOMMENDED_SCRIPTS = %w[
        Latin Han Hiragana Katakana Hangul Bopomofo Yi
      ].freeze

      # UTS #39 Table 5b (Aspirational Scripts).
      ASPIRATIONAL_SCRIPTS = %w[
        Arabic Armenian Bengali Canadian_Aboriginal Cherokee Cyrillic
        Devanagari Ethiopic Georgian Greek Gujarati Gurmukhi Hebrew
        Kannada Khmer Lao Malayalam Mongolian Myanmar Oriya Sinhala
        Tamil Telugu Thaana Thai Tibetan Tifinagh
      ].freeze

      # UTS #39 Table 7 (Limited Use Scripts).
      LIMITED_USE_SCRIPTS = %w[
        Adlam Balinese Bamum Batak Buginese Buhid Chakma Cham Coptic
        Glagolitic Gothic Hanunoo Javanese Kayah_Li Kharoshthi Lepcha
        Limbu Linear_B Lisu Lycian Lydian Mandaic Meetei_Mayek
        Meroitic_Cursive Meroitic_Hieroglyphs Miao New_Tai_Lue Nko Ogham
        Ol_Chiki Old_Italic Old_Permic Old_Persian Old_South_Arabian
        Old_Turkic Osmanya Phags_Pa Rejang Runic Samaritan Saurashtra
        Shavian Sundanese Syloti_Nagri Syriac Tagalog Tagbanwa Tai_Le
        Tai_Tham Tai_Viet Takri
      ].freeze

      # Scripts allowed in minimally restrictive identifiers and above.
      ALLOWED_SCRIPTS = (RECOMMENDED_SCRIPTS + ASPIRATIONAL_SCRIPTS).freeze

      # UTS #39 Section 3.1 script combinations for highly restrictive
      # identifiers (Japanese, Korean and Chinese mixtures with Latin).
      JAPANESE_COMBINATION = %w[Latin Han Hiragana Katakana].freeze
      KOREAN_COMBINATION = %w[Latin Han Hangul].freeze
      CHINESE_COMBINATION = %w[Latin Han Bopomofo].freeze

      HIGHLY_RESTRICTIVE_COMBINATIONS = [
        JAPANESE_COMBINATION,
        KOREAN_COMBINATION,
        CHINESE_COMBINATION
      ].freeze

      # Scripts excluded from moderately restrictive identifiers because
      # they contain too many Latin lookalikes.
      MODERATELY_RESTRICTIVE_EXCLUSIONS = %w[Cyrillic Greek].freeze

      ASCII_MAX = 0x7F

      class << self
        # Computes the restriction level for a resolved identifier.
        #
        # @param resolution [TwitterCldr::Security::ScriptResolver]
        # @param identifier_allowed [Boolean] whether every character
        #   satisfies the identifier character profile
        # @return [Symbol] one of LEVELS
        def level_for(resolution, identifier_allowed:)
          return :unrestricted unless identifier_allowed
          return :ascii if ascii?(resolution)

          scripts = resolution.scripts
          alternates = resolution.alternates

          return :single_script if scripts.size <= 1

          if HIGHLY_RESTRICTIVE_COMBINATIONS.any? do |combination|
               covered_by?(scripts, alternates, combination)
             end
            return :highly_restrictive
          end

          return :moderately_restrictive if moderately_restrictive?(scripts, alternates)
          return :minimally_restrictive if covered_by?(scripts, alternates, ALLOWED_SCRIPTS)

          :unrestricted
        end

        private

        def ascii?(resolution)
          resolution.characters.all? { |char| char.codepoint <= ASCII_MAX }
        end

        # True when every definite script is in the allowed set and every
        # ambiguous Common/Inherited character is usable with at least one
        # allowed script.
        def covered_by?(scripts, alternates, allowed)
          (scripts - allowed).empty? &&
            alternates.all? { |set| (set & allowed).any? }
        end

        # Latin mixed with at most one other Recommended or Aspirational
        # script, except Cyrillic and Greek.
        def moderately_restrictive?(scripts, alternates)
          return false unless scripts.include?('Latin')

          others = scripts - ['Latin']
          return false unless others.size == 1
          return false if MODERATELY_RESTRICTIVE_EXCLUSIONS.include?(others.first)

          covered_by?(scripts, alternates, ['Latin'] + others)
        end
      end
    end
  end
end
