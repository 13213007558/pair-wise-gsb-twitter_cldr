# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Security
    # Resolves the set of scripts an identifier can be written with,
    # following UTS #39 Sections 3.1 and 5.1.
    #
    # For each character:
    #
    # * If the Script property value is neither Common nor Inherited, the
    #   character contributes exactly that script.
    # * If the Script value is Common or Inherited, the Script_Extensions
    #   (scx) value is used instead. Characters not listed in
    #   Script_Extensions have scx = { Script }, i.e. { Common } or
    #   { Inherited }, and therefore contribute no script (this is what
    #   keeps ASCII digits and punctuation from polluting the script set).
    #
    # A Common/Inherited character whose scx contains a single script
    # contributes that script. One whose scx contains several scripts
    # (e.g. U+30FB KATAKANA MIDDLE DOT, usable with Han, Hiragana,
    # Katakana, Bopomofo, Hangul and Yi) is recorded as an alternates set
    # instead of adding every one of those scripts to the identifier.
    # This is what allows normal Japanese mixed-script names to resolve
    # to exactly the scripts they are written in.
    class ScriptResolver
      COMMON = 'Common'.freeze
      INHERITED = 'Inherited'.freeze
      SCRIPTLESS = [COMMON, INHERITED].freeze

      ResolvedCharacter = Struct.new(:character, :codepoint, :script, :script_set) do
        # True when the character is Common/Inherited and its
        # Script_Extensions value contains more than one script.
        def ambiguous?
          script_set.size > 1
        end
      end

      attr_reader :string, :characters

      def self.resolve(string)
        new(string)
      end

      def initialize(string)
        @string = string.to_s
        @characters = @string.each_char.map { |char| resolve_char(char) }.freeze
      end

      # The definite scripts of the identifier: the union of all
      # single-script resolutions, in order of first appearance.
      #
      # @return [Array<String>] e.g. ['Han', 'Katakana']
      def scripts
        @scripts ||= characters.each_with_object([]) do |char, ret|
          ret.concat(char.script_set) if char.script_set.size == 1
        end.uniq.freeze
      end

      # The alternates sets of ambiguous Common/Inherited characters.
      #
      # @return [Array<Array<String>>] e.g. [['Hira', 'Kana']]
      def alternates
        @alternates ||= characters.select(&:ambiguous?).map(&:script_set).uniq.freeze
      end

      def mixed_script?
        scripts.size > 1
      end

      private

      def resolve_char(char)
        codepoint = char.ord
        properties = properties_for(codepoint)
        script = (properties['Script'] || ['Unknown']).first
        extensions = properties['Script_Extensions']

        script_set =
          if SCRIPTLESS.include?(script)
            # Script_Extensions values use ISO 15924 short codes (e.g.
            # "Kana"), normalize them to long script names (e.g.
            # "Katakana") so they can be compared with Script values.
            (extensions || [script]).to_a.map { |sc| normalize_script(sc) }
          else
            [script]
          end

        ResolvedCharacter.new(char, codepoint, script, script_set - SCRIPTLESS)
      end

      def properties_for(codepoint)
        TwitterCldr::Shared::CodePoint.get(codepoint).properties.properties_hash
      end

      def normalize_script(script)
        TwitterCldr::Shared::PropertyValueAliases.long_alias_for('sc', script) || script
      end
    end
  end
end
