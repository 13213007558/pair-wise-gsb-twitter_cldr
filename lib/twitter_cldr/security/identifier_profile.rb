# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Security
    # Structured result of the UTS #39 identifier checks for a single
    # string. Exposes the skeleton, the restriction level, the resolved
    # script set and the specific reasons behind the verdict, so callers
    # never have to rely on a single "dangerous" boolean.
    class IdentifierProfile
      attr_reader :string

      def initialize(string)
        @string = string.to_s
      end

      # UTS #39 Section 4 skeleton (case-preserving).
      def skeleton
        @skeleton ||= Confusables.skeleton(string)
      end

      # Case-folded skeleton (twitter-cldr extension). Two identifiers
      # that differ only in case share the same case-folded skeleton but
      # not the same skeleton.
      def case_folded_skeleton
        @case_folded_skeleton ||= Confusables.skeleton(string, case_sensitive: false)
      end

      # @return [TwitterCldr::Security::ScriptResolver]
      def resolution
        @resolution ||= ScriptResolver.resolve(string)
      end

      # The definite scripts of the identifier, in order of first
      # appearance (e.g. [:Han, :Katakana]).
      #
      # @return [Array<Symbol>]
      def scripts
        resolution.scripts.map(&:to_sym)
      end

      # Script_Extensions alternates for ambiguous Common/Inherited
      # characters (e.g. KATAKANA MIDDLE DOT).
      #
      # @return [Array<Array<Symbol>>]
      def script_alternates
        resolution.alternates.map { |set| set.map(&:to_sym) }
      end

      # UTS #39 Section 3.1 restriction level.
      #
      # @return [Symbol] one of :ascii, :single_script,
      #   :highly_restrictive, :moderately_restrictive,
      #   :minimally_restrictive or :unrestricted
      def restriction_level
        @restriction_level ||=
          RestrictionLevel.level_for(
            resolution,
            identifier_allowed: identifier_characters_allowed?
          )
      end

      # True when the identifier satisfies the minimally restrictive level
      # or better, i.e. it contains only identifier-appropriate characters
      # from Recommended or Aspirational scripts.
      def allowed?
        restriction_level != :unrestricted
      end

      # The specific reasons behind the verdict, most specific first.
      # Each entry is a Hash with a :code key plus details:
      #
      #   { code: :non_identifier_character, character: ' ', codepoint: 'U+0020' }
      #   { code: :default_ignorable_character, character: "​", codepoint: 'U+200B' }
      #   { code: :limited_use_script, script: :Runic }
      #   { code: :exclusion_script, script: :Braille }
      #   { code: :mixed_scripts, scripts: [:Latin, :Cyrillic] }
      #
      # :mixed_scripts is informational: legitimate identifiers (e.g.
      # Japanese names) mix scripts all the time. The other codes explain
      # why an identifier is :unrestricted.
      #
      # @return [Array<Hash>]
      def reasons
        @reasons ||= compute_reasons.freeze
      end

      # Compares this identifier with another one. Returns nil when the
      # two are not confusable, otherwise a Hash describing the relation:
      #
      #   { type: :whole_script, skeleton: 'paypal', case_sensitive: true,
      #     scripts: [:Latin], other_scripts: [:Cyrillic] }
      #
      # Pass case_sensitive: false to compare case-folded skeletons, which
      # catches identifiers that differ only in case.
      def confusable_with?(other, case_sensitive: true)
        other = self.class.new(other) unless other.is_a?(IdentifierProfile)

        own_skeleton = case_sensitive ? skeleton : case_folded_skeleton
        other_skeleton = case_sensitive ? other.skeleton : other.case_folded_skeleton

        return nil unless own_skeleton == other_skeleton

        {
          type: whole_script_confusable?(other) ? :whole_script : :mixed_script,
          skeleton: own_skeleton,
          case_sensitive: case_sensitive,
          scripts: scripts,
          other_scripts: other.scripts
        }
      end

      def to_h
        {
          string: string,
          skeleton: skeleton,
          case_folded_skeleton: case_folded_skeleton,
          restriction_level: restriction_level,
          scripts: scripts,
          script_alternates: script_alternates,
          reasons: reasons,
          allowed: allowed?
        }
      end

      private

      def whole_script_confusable?(other)
        resolution.scripts.size <= 1 && other.resolution.scripts.size <= 1
      end

      def compute_reasons
        character_reasons + script_reasons + mixed_script_reasons
      end

      def character_reasons
        resolution.characters.each_with_object([]) do |char, ret|
          unless identifier_character?(char.codepoint)
            ret << {
              code: :non_identifier_character,
              character: char.character,
              codepoint: format('U+%04X', char.codepoint)
            }
          end

          if default_ignorable?(char.codepoint)
            ret << {
              code: :default_ignorable_character,
              character: char.character,
              codepoint: format('U+%04X', char.codepoint)
            }
          end
        end
      end

      def script_reasons
        resolution.scripts.each_with_object([]) do |script, ret|
          if RestrictionLevel::LIMITED_USE_SCRIPTS.include?(script)
            ret << { code: :limited_use_script, script: script.to_sym }
          elsif !RestrictionLevel::ALLOWED_SCRIPTS.include?(script)
            ret << { code: :exclusion_script, script: script.to_sym }
          end
        end
      end

      def mixed_script_reasons
        return [] unless resolution.scripts.size > 1

        [{ code: :mixed_scripts, scripts: scripts }]
      end

      # Approximates the UTS #39 Identifier_Type "Recommended + Inclusion"
      # profile: every character must be an ID_Start/ID_Continue character
      # that is not Default_Ignorable, every resolved script must be
      # Recommended or Aspirational, and every ambiguous Common/Inherited
      # character must be usable with at least one such script.
      def identifier_characters_allowed?
        resolution.characters.all? do |char|
          identifier_character?(char.codepoint) &&
            !default_ignorable?(char.codepoint)
        end &&
          resolution.scripts.all? do |script|
            RestrictionLevel::ALLOWED_SCRIPTS.include?(script)
          end &&
          resolution.alternates.all? do |alternates|
            (alternates & RestrictionLevel::ALLOWED_SCRIPTS).any?
          end
      end

      def identifier_character?(codepoint)
        self.class.id_start_set.include?(codepoint) ||
          self.class.id_continue_set.include?(codepoint)
      end

      def default_ignorable?(codepoint)
        self.class.default_ignorable_set.include?(codepoint)
      end

      class << self
        def id_start_set
          @id_start_set ||= properties.code_points_for_property('ID_Start')
        end

        def id_continue_set
          @id_continue_set ||= properties.code_points_for_property('ID_Continue')
        end

        def default_ignorable_set
          @default_ignorable_set ||=
            properties.code_points_for_property('Default_Ignorable_Code_Point')
        end

        private

        def properties
          TwitterCldr::Shared::CodePoint.properties
        end
      end
    end
  end
end
