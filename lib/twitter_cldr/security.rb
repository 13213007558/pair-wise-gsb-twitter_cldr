# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  # UTS #39 (Unicode Security Mechanisms) identifier checks.
  #
  # Designed for account systems that need to spot spoofed display names
  # (e.g. Latin lookalikes written with Cyrillic letters) without rejecting
  # legitimate non-Latin or mixed-script identifiers (e.g. Japanese names
  # mixing Han, Hiragana and Katakana).
  #
  # All data is pinned to TwitterCldr::Versions::UNICODE_VERSION, the same
  # Unicode version as the bundled character property data.
  #
  # Supported checks (see TwitterCldr::Security.supported_checks):
  #
  # 1. Skeleton computation (UTS #39, Section 4) for confusable detection,
  #    plus a case-folded variant for case-insensitive comparison.
  # 2. Restriction level detection (UTS #39, Section 3.1): :ascii,
  #    :single_script, :highly_restrictive, :moderately_restrictive,
  #    :minimally_restrictive or :unrestricted.
  # 3. Script set resolution (UTS #39, Sections 3.1 and 5.1) that correctly
  #    handles the Common and Inherited script values and the
  #    Script_Extensions property.
  # 4. Identifier character validation, approximating the UTS #39
  #    Identifier_Type "Recommended + Inclusion" profile with the ID_Start,
  #    ID_Continue and Default_Ignorable_Code_Point properties.
  # 5. Confusable comparison between two identifiers, classified as
  #    :whole_script or :mixed_script (UTS #39, Section 5.2).
  #
  # Every check returns structured results (skeleton strings, restriction
  # level symbols, script sets and specific reason codes) instead of a
  # single "dangerous" boolean, so callers can decide what to allow.
  module Security
    autoload :Confusables,       'twitter_cldr/security/confusables'
    autoload :IdentifierProfile, 'twitter_cldr/security/identifier_profile'
    autoload :RestrictionLevel,  'twitter_cldr/security/restriction_level'
    autoload :ScriptResolver,    'twitter_cldr/security/script_resolver'

    SUPPORTED_CHECKS = {
      skeleton: 'UTS #39 Section 4 skeleton (NFD, apply confusable mappings, '+        'NFD). Case-preserving; use case_folded_skeleton for a '+        'case-insensitive variant.',
      restriction_level: 'UTS #39 Section 3.1 restriction level: :ascii, '+        ':single_script, :highly_restrictive, :moderately_restrictive, '+        ':minimally_restrictive or :unrestricted.',
      script_resolution: 'Script set resolution per UTS #39 Sections 3.1 '+        'and 5.1. Common/Inherited characters resolve through '+        'Script_Extensions; multi-script characters are reported as '+        'alternates instead of polluting the identifier script set.',
      identifier_characters: 'Identifier character validation approximating '+        'the UTS #39 Identifier_Type Recommended+Inclusion profile via the '+        'ID_Start, ID_Continue and Default_Ignorable_Code_Point properties.',
      confusable_comparison: 'Pairwise confusable detection via skeleton '+        'equality, classified as :whole_script or :mixed_script per '+        'UTS #39 Section 5.2. Available case-sensitively (default) or '+        'case-insensitively.'
    }.freeze

    class << self
      # Builds a full identifier profile for the given string.
      #
      # @param string [String] the identifier to check
      # @return [TwitterCldr::Security::IdentifierProfile]
      def check_identifier(string)
        IdentifierProfile.new(string)
      end

      # Computes the UTS #39 skeleton of the given string.
      #
      # @param string [String]
      # @param case_sensitive [Boolean] pass false for the case-folded variant
      # @return [String]
      def skeleton(string, case_sensitive: true)
        Confusables.skeleton(string, case_sensitive: case_sensitive)
      end

      # @return [Hash] description of the checks supported by this module
      def supported_checks
        SUPPORTED_CHECKS
      end

      # The Unicode version the security data is pinned to. Always matches
      # the bundled character property data.
      #
      # @return [String]
      def unicode_version
        TwitterCldr::Versions.unicode_version
      end
    end
  end
end
