# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'set'

module TwitterCldr
  module Shared

    # Implements a subset of UTS #39 (Unicode Security Mechanisms) checks
    # for user identifiers such as account names, so that visually
    # confusable cross-script spoofs (e.g. a Cyrillic "а" inside an
    # otherwise Latin name) can be detected without rejecting legitimate
    # non-Latin identifiers.
    #
    # Supported checks:
    #
    # * +skeleton+ - the UTS #39 skeleton (section 4, Confusable
    #   Detection). Two identifiers are confusable when their skeletons
    #   are identical. Skeletons are case-sensitive, so identifiers that
    #   differ only in case are *not* confusable.
    # * +script_set+ - the identifier's script set (section 5.1),
    #   resolving Common and Inherited characters through the
    #   Script_Extensions property.
    # * +restriction_level+ - the UTS #39 restriction level (section
    #   5.2): +:ascii_only+, +:highly_restrictive+,
    #   +:moderately_restrictive+, +:minimally_restrictive+, or
    #   +:unrestricted+.
    # * +check+ - a structured Result with the skeleton, script set,
    #   restriction level, and the concrete reasons (with offending code
    #   points) that make the identifier risky.
    # * +compare+ / +confusable?+ - pairwise comparison of two
    #   identifiers, distinguishing skeleton matches, case-only
    #   differences, and distinct identifiers.
    #
    # Not implemented (out of scope): whole-script confusables (UTS #39
    # section 4.1), mixed-number detection, and the bidi checks of
    # UTS #39 section 4.2.
    #
    # Data is pinned to Unicode 16.0.0 (TwitterCldr::Versions::UNICODE_VERSION)
    # in resources/shared/identifier_security.yml. The confusables table is
    # a curated subset of confusables.txt covering the highest-risk
    # cross-script homoglyphs; see the data file for details.
    #
    # @example
    #   result = TwitterCldr::Shared::IdentifierSecurity.check("p\u0430ypal")
    #   result.skeleton             # => "paypal"
    #   result.restriction_level    # => :moderately_restrictive
    #   result.reasons.map(&:code)  # => [:mixed_scripts]
    module IdentifierSecurity
      # A single, concrete reason why an identifier (or a pair of
      # identifiers) is considered risky. +code+ is a machine-readable
      # symbol, +message+ a human-readable explanation, +code_points+ the
      # offending code points grouped by script (when applicable), and
      # +scripts+ the scripts involved (when applicable).
      Reason = Struct.new(:code, :message, :code_points, :scripts, keyword_init: true)

      # The result of checking a single identifier.
      class Result
        attr_reader :identifier, :skeleton, :scripts, :restriction_level, :reasons

        def initialize(identifier:, skeleton:, scripts:, restriction_level:, reasons:)
          @identifier = identifier
          @skeleton = skeleton
          @scripts = scripts
          @restriction_level = restriction_level
          @reasons = reasons
        end

        def safe?
          reasons.empty?
        end

        def mixed_script?
          scripts.size > 1
        end
      end

      # The result of comparing two identifiers.
      class Comparison
        attr_reader :first, :second, :reasons

        def initialize(first:, second:, reasons:)
          @first = first
          @second = second
          @reasons = reasons
        end

        def identical?
          reasons.any? { |reason| reason.code == :identical }
        end

        # True when both identifiers reduce to the same skeleton, i.e.
        # they are visually confusable per UTS #39.
        def confusable?
          reasons.any? { |reason| reason.code == :skeleton_match }
        end

        # True when the identifiers differ only in letter case. Such
        # pairs are *not* confusable per UTS #39 (skeletons are
        # case-sensitive), but account systems may still want to treat
        # them as equivalent.
        def case_only_difference?
          reasons.any? { |reason| reason.code == :case_only_difference }
        end
      end

      COMMON    = 'Common'.freeze
      INHERITED = 'Inherited'.freeze
      COMMON_OR_INHERITED = [COMMON, INHERITED].freeze

      # Script combinations explicitly allowed by UTS #39 section 5.2
      # (Highly Restrictive): Japanese, Chinese, and Korean mixtures.
      JAPANESE_SCRIPTS = %w[Han Hiragana Katakana].freeze
      CHINESE_SCRIPTS  = %w[Han Bopomofo].freeze
      KOREAN_SCRIPTS   = %w[Han Hangul].freeze

      RESTRICTION_LEVELS = [
        :ascii_only,
        :highly_restrictive,
        :moderately_restrictive,
        :minimally_restrictive,
        :unrestricted
      ].freeze

      class << self
        # The UTS #39 skeleton of +identifier+: NFD, replace each
        # confusable character by its prototype, then NFD again.
        def skeleton(identifier)
          decomposed = TwitterCldr::Normalization.normalize(identifier.to_s, using: :nfd)

          mapped = decomposed.each_codepoint.map do |code_point|
            confusables.fetch(code_point) { [code_point] }.pack('U*')
          end.join

          TwitterCldr::Normalization.normalize(mapped, using: :nfd)
        end

        # The script set of +identifier+ per UTS #39 section 5.1.
        #
        # For each character, the Script_Extensions value is used
        # (falling back to the Script value). Characters whose resolved
        # set is only Common and/or Inherited (digits, most punctuation)
        # contribute nothing. Characters with a singleton script set add
        # that script. Characters with multiple script extensions (e.g.
        # Inherited combining marks usable with several scripts) only
        # contribute when the identifier has no singleton scripts at
        # all, in which case the intersection of all such sets is used.
        #
        # @return [Set<String>] set of long script names, e.g. #<Set: {"Latin", "Cyrillic"}>
        def script_set(identifier)
          scripts = Set.new
          alternates = nil

          identifier.to_s.each_codepoint do |code_point|
            resolved = resolved_script_set(code_point)
            next if resolved.empty?

            if resolved.size == 1
              scripts << resolved.first
            else
              alternates = alternates ? alternates & resolved : resolved
            end
          end

          scripts.empty? && alternates ? alternates : scripts
        end

        # The UTS #39 restriction level of +identifier+ (section 5.2).
        #
        # @return [Symbol] one of RESTRICTION_LEVELS
        def restriction_level(identifier)
          identifier = identifier.to_s
          return :ascii_only if identifier.ascii_only?

          scripts = script_set(identifier)

          return :highly_restrictive if scripts.size <= 1
          return :highly_restrictive if allowed_cjk_mix?(scripts)
          return :moderately_restrictive if latin_plus_one?(scripts)
          return :minimally_restrictive if covered_scripts?(scripts)

          :unrestricted
        end

        # Checks +identifier+ and returns a Result with the skeleton,
        # script set, restriction level, and concrete reasons.
        def check(identifier)
          identifier = identifier.to_s
          scripts = script_set(identifier)
          level = restriction_level(identifier)

          Result.new(
            identifier: identifier,
            skeleton: skeleton(identifier),
            scripts: scripts,
            restriction_level: level,
            reasons: reasons_for(identifier, scripts)
          )
        end

        # True when +first+ and +second+ are confusable, i.e. their
        # skeletons are identical.
        def confusable?(first, second)
          skeleton(first) == skeleton(second)
        end

        # Compares two identifiers and returns a Comparison. Each side
        # is checked individually (see #check), and the pair is
        # classified as identical, a skeleton match (confusable), a
        # case-only difference, or distinct.
        def compare(first, second)
          first = first.to_s
          second = second.to_s

          reasons =
            if first == second
              [Reason.new(code: :identical, message: 'identifiers are identical')]
            elsif confusable?(first, second)
              [Reason.new(
                code: :skeleton_match,
                message: "identifiers are confusable: both have skeleton #{skeleton(first).inspect}"
              )]
            elsif Casefolder.full_casefold(first) == Casefolder.full_casefold(second)
              [Reason.new(
                code: :case_only_difference,
                message: 'identifiers differ only in letter case'
              )]
            else
              [Reason.new(code: :distinct, message: 'identifiers are distinct')]
            end

          Comparison.new(first: check(first), second: check(second), reasons: reasons)
        end

        # The Unicode version the security data is pinned to.
        def unicode_version
          data.fetch(:unicode_version)
        end

        private

        def reasons_for(identifier, scripts)
          reasons = []

          if scripts.size > 1 && !allowed_cjk_mix?(scripts)
            reasons << Reason.new(
              code: :mixed_scripts,
              message: "identifier mixes scripts: #{scripts.to_a.sort.join(', ')}",
              code_points: code_points_by_script(identifier),
              scripts: scripts.to_a.sort
            )
          end

          uncovered = scripts.to_a.sort - covered_scripts

          unless uncovered.empty?
            reasons << Reason.new(
              code: :non_recommended_script,
              message: "identifier contains scripts that are not recommended " +                "for identifiers: #{uncovered.join(', ')}",
              scripts: uncovered
            )
          end

          reasons
        end

        # Groups the code points of +identifier+ by their (singleton)
        # resolved script, so callers can see exactly which characters
        # introduce each script.
        def code_points_by_script(identifier)
          identifier.each_codepoint.each_with_object({}) do |code_point, result|
            resolved = resolved_script_set(code_point)
            (result[resolved.first] ||= []) << code_point if resolved.size == 1
          end
        end

        # The resolved script set of a single code point: its
        # Script_Extensions value (long names), falling back to the
        # Script value, with Common and Inherited removed.
        def resolved_script_set(code_point)
          properties = CodePoint.properties_for_code_point(code_point)
          extensions = properties.script_extensions

          scripts =
            if extensions == ['<script>']
              properties.script
            else
              extensions.map { |short| long_script_name(short) }
            end

          Set.new(scripts) - COMMON_OR_INHERITED
        end

        def long_script_name(short_name)
          PropertyValueAliases.long_alias_for('sc', short_name) || short_name
        end

        def allowed_cjk_mix?(scripts)
          subset_of?(scripts, JAPANESE_SCRIPTS) ||
            subset_of?(scripts, CHINESE_SCRIPTS) ||
            subset_of?(scripts, KOREAN_SCRIPTS)
        end

        def subset_of?(scripts, allowed)
          scripts.all? { |script| allowed.include?(script) }
        end

        # Latin mixed with exactly one other Recommended or Aspirational
        # script (UTS #39 Moderately Restrictive).
        def latin_plus_one?(scripts)
          scripts.size == 2 && scripts.include?('Latin') && covered_scripts?(scripts)
        end

        def covered_scripts?(scripts)
          scripts.all? { |script| covered_scripts.include?(script) }
        end

        def covered_scripts
          @covered_scripts ||= recommended_scripts + aspirational_scripts
        end

        def recommended_scripts
          data.fetch(:recommended_scripts)
        end

        def aspirational_scripts
          data.fetch(:aspirational_scripts)
        end

        def confusables
          @confusables ||= data.fetch(:confusables)
        end

        def data
          @data ||= TwitterCldr.get_resource(:shared, :identifier_security)
        end
      end
    end
  end
end
