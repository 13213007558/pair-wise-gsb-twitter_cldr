# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Security do
  def check(string)
    TwitterCldr::Security.check_identifier(string)
  end

  describe '.supported_checks' do
    it 'documents the supported UTS #39 checks' do
      expect(TwitterCldr::Security.supported_checks.keys).to match_array(%i[
        skeleton
        restriction_level
        script_resolution
        identifier_characters
        confusable_comparison
      ])
    end
  end

  describe '.unicode_version' do
    it 'matches the Unicode version of the bundled property data' do
      expect(TwitterCldr::Security.unicode_version).to eq(
        TwitterCldr::Versions.unicode_version
      )
    end
  end

  describe 'skeleton computation' do
    it 'leaves ordinary strings untouched' do
      expect(check('paypal').skeleton).to eq('paypal')
    end

    it 'maps Cyrillic homoglyphs to their Latin prototypes' do
      # Cyrillic Er, A, U, Er, A + Latin l
      expect(check("раураl").skeleton).to eq('paypal')
    end

    it 'maps fullwidth characters to ASCII' do
      expect(check("ｕｓｅｒ１２３").skeleton).to eq('user123')
    end

    it 'is case-preserving' do
      expect(check('John').skeleton).to eq('John')
      expect(check('john').skeleton).to eq('john')
    end

    it 'exposes a case-folded variant' do
      expect(check('John').case_folded_skeleton).to eq('john')
      expect(check('john').case_folded_skeleton).to eq('john')
    end
  end

  describe 'script set resolution' do
    it 'resolves definite scripts in order of appearance' do
      expect(check("鈴木タロウ").scripts).to eq(%i[Han Katakana])
    end

    it 'ignores Common characters without Script_Extensions (digits, punctuation)' do
      expect(check('さとう123').scripts).to eq(%i[Hiragana])
    end

    it 'resolves Common characters through single-script Script_Extensions' do
      # U+30FC PROLONGED SOUND MARK is Common with scx = { Hiragana, Katakana }
      profile = check("メモー")
      expect(profile.scripts).to eq(%i[Katakana])
      expect(profile.script_alternates).to eq([%i[Hiragana Katakana]])
    end

    it 'records multi-script Script_Extensions as alternates instead of polluting the script set' do
      # U+30FB KATAKANA MIDDLE DOT is Common with scx = { Bopomofo, Hangul,
      # Han, Hiragana, Katakana, Yi }
      profile = check("タロウ・タロウ")
      expect(profile.scripts).to eq(%i[Katakana])
      expect(profile.script_alternates).to eq(
        [%i[Bopomofo Hangul Han Hiragana Katakana Yi]]
      )
    end

    it 'resolves Inherited characters (combining marks) through Script_Extensions' do
      # 'cafe' + U+0301 COMBINING ACUTE ACCENT (Script = Inherited)
      profile = check("café")
      expect(profile.scripts).to eq(%i[Latin])
      expect(profile.script_alternates.flatten).to include(:Latin)
    end
  end

  describe 'restriction levels' do
    it 'detects ASCII identifiers' do
      expect(check('paypal').restriction_level).to eq(:ascii)
    end

    it 'detects single-script identifiers' do
      expect(check("山田太郎").restriction_level).to eq(:single_script)
      expect(check("ѕсоре").restriction_level).to eq(:single_script)
    end

    it 'allows the Japanese script combination at the highly restrictive level' do
      expect(check("鈴木タロウ").restriction_level).to eq(:highly_restrictive)
      expect(check("田中タロウ090").restriction_level).to eq(:highly_restrictive)
      expect(check("abcタロ").restriction_level).to eq(:highly_restrictive)
    end

    it 'allows Latin plus one non-Cyrillic, non-Greek script at the moderately restrictive level' do
      expect(check("userかな").restriction_level).to eq(:highly_restrictive) # Latin+Hiragana is highly restrictive
      expect(check("userمرحبا").restriction_level).to eq(:moderately_restrictive)
    end

    it 'treats Latin+Cyrillic and Latin+Greek mixtures as minimally restrictive' do
      expect(check("раураl").restriction_level).to eq(:minimally_restrictive)
      expect(check("abcμαζα").restriction_level).to eq(:minimally_restrictive)
    end

    it 'rejects non-identifier characters' do
      profile = check('user name')
      expect(profile.restriction_level).to eq(:unrestricted)
      expect(profile.allowed?).to be(false)
    end

    it 'rejects Limited Use scripts' do
      profile = check("ᚠᚢᚦ") # Runic
      expect(profile.restriction_level).to eq(:unrestricted)
      expect(profile.allowed?).to be(false)
    end

    it 'rejects Default_Ignorable characters' do
      profile = check("user​") # contains U+200B ZERO WIDTH SPACE
      expect(profile.restriction_level).to eq(:unrestricted)
      expect(profile.allowed?).to be(false)
    end
  end

  describe 'reasons' do
    it 'is empty for a plain single-script identifier' do
      expect(check("山田太郎").reasons).to be_empty
    end

    it 'reports mixed scripts as informational' do
      expect(check("鈴木タロウ").reasons).to eq(
        [{ code: :mixed_scripts, scripts: %i[Han Katakana] }]
      )
    end

    it 'reports non-identifier characters with their codepoints' do
      expect(check('user name').reasons).to eq(
        [{ code: :non_identifier_character, character: ' ', codepoint: 'U+0020' }]
      )
    end

    it 'reports default-ignorable characters' do
      reasons = check("user​").reasons
      expect(reasons).to include(
        code: :default_ignorable_character, character: "​", codepoint: 'U+200B'
      )
    end

    it 'reports Limited Use scripts' do
      expect(check("ᚠᚢᚦ").reasons).to eq(
        [{ code: :limited_use_script, script: :Runic }]
      )
    end
  end

  describe 'a normal Japanese mixed-script name' do
    let(:profile) { check("鈴木タロウ") }

    it 'is allowed' do
      expect(profile.allowed?).to be(true)
    end

    it 'is highly restrictive' do
      expect(profile.restriction_level).to eq(:highly_restrictive)
    end

    it 'is not confusable with its own spelling in another script' do
      expect(profile.confusable_with?("鈴木タロウ")).not_to be_nil
      expect(profile.confusable_with?("鈴木タロウ1")).to be_nil
    end
  end

  describe 'two visually identical cross-script names' do
    let(:latin) { check('paypal') }
    let(:spoof) { check("раураl") } # Cyrillic Er, A, U, Er, A + Latin l

    it 'gives them the same skeleton' do
      expect(spoof.skeleton).to eq(latin.skeleton)
    end

    it 'keeps distinct restriction levels for each name' do
      expect(latin.restriction_level).to eq(:ascii)
      expect(spoof.restriction_level).to eq(:minimally_restrictive)
    end

    it 'classifies the pair as a mixed-script confusable' do
      result = latin.confusable_with?(spoof)
      expect(result[:type]).to eq(:mixed_script)
      expect(result[:scripts]).to eq(%i[Latin])
      expect(result[:other_scripts]).to eq(%i[Cyrillic Latin])
    end

    it 'classifies single-script lookalikes as whole-script confusables' do
      result = check('scope').confusable_with?("ѕсоре")
      expect(result[:type]).to eq(:whole_script)
    end
  end

  describe 'names that differ only in case' do
    let(:upper) { check('John') }
    let(:lower) { check('john') }

    it 'gives them different skeletons' do
      expect(upper.skeleton).not_to eq(lower.skeleton)
    end

    it 'is not confusable under the default case-sensitive comparison' do
      expect(upper.confusable_with?(lower)).to be_nil
    end

    it 'is confusable under case-insensitive comparison' do
      result = upper.confusable_with?(lower, case_sensitive: false)
      expect(result[:type]).to eq(:whole_script)
      expect(result[:skeleton]).to eq('john')
      expect(result[:case_sensitive]).to be(false)
    end

    it 'shares the same case-folded skeleton' do
      expect(upper.case_folded_skeleton).to eq(lower.case_folded_skeleton)
    end
  end

  describe '#to_h' do
    it 'returns a structured result instead of a single boolean' do
      result = check("鈴木タロウ").to_h
      expect(result[:string]).to eq("鈴木タロウ")
      expect(result[:skeleton]).to eq("鈴木タロウ")
      expect(result[:restriction_level]).to eq(:highly_restrictive)
      expect(result[:scripts]).to eq(%i[Han Katakana])
      expect(result[:reasons]).to eq(
        [{ code: :mixed_scripts, scripts: %i[Han Katakana] }]
      )
      expect(result[:allowed]).to be(true)
    end
  end
end
