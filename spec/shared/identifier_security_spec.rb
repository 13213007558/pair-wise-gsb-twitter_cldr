# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Shared::IdentifierSecurity do
  let(:security) { TwitterCldr::Shared::IdentifierSecurity }

  describe 'data versioning' do
    it 'is pinned to the Unicode version used by the rest of the library' do
      expect(security.unicode_version).to eq(TwitterCldr::Versions::UNICODE_VERSION)
    end
  end

  describe '#skeleton' do
    it 'maps Cyrillic homoglyphs to their Latin prototypes' do
      expect(security.skeleton("p\u0430yp\u0430l")).to eq('paypal')
    end

    it 'maps Greek homoglyphs to their Latin prototypes' do
      expect(security.skeleton("\u03B1\u03B2\u03B3")).to eq("a\u00DFy")
    end

    it 'maps fullwidth Latin letters to ASCII' do
      expect(security.skeleton("\uFF50\uFF41\uFF59\uFF50\uFF41\uFF4C")).to eq('paypal')
    end

    it 'is case-sensitive' do
      expect(security.skeleton('John')).to eq('John')
      expect(security.skeleton('john')).to eq('john')
      expect(security.skeleton('John')).not_to eq(security.skeleton('john'))
    end

    it 'leaves identifiers without confusables unchanged' do
      expect(security.skeleton('alice')).to eq('alice')
    end
  end

  describe '#script_set' do
    it 'resolves a single script' do
      expect(security.script_set('paypal')).to eq(Set['Latin'])
    end

    it 'detects mixed scripts' do
      expect(security.script_set("p\u0430ypal")).to eq(Set['Latin', 'Cyrillic'])
    end

    it 'ignores Common characters such as digits and punctuation' do
      expect(security.script_set('user_123')).to eq(Set['Latin'])
    end

    it 'resolves Common characters through Script_Extensions' do
      # U+30FC KATAKANA-HIRAGANA PROLONGED SOUND MARK has Script=Common
      # and Script_Extensions={Hiragana, Katakana}
      expect(security.script_set("\u30AB\u30BF\u30FC")).to eq(Set['Katakana'])
      expect(security.script_set("\u30FC")).to eq(Set['Hiragana', 'Katakana'])
    end

    it 'does not let Inherited combining marks pollute the script set' do
      # U+0301 COMBINING ACUTE ACCENT has Script=Inherited and a
      # multi-script Script_Extensions value
      expect(security.script_set("cafe\u0301")).to eq(Set['Latin'])
    end
  end

  describe '#restriction_level' do
    it 'is ascii_only for pure ASCII identifiers' do
      expect(security.restriction_level('paypal')).to eq(:ascii_only)
    end

    it 'is highly_restrictive for single-script non-ASCII identifiers' do
      expect(security.restriction_level("\u0434\u0438\u043C\u0430")).to eq(:highly_restrictive)
    end

    it 'is highly_restrictive for Japanese Han/Hiragana/Katakana mixtures' do
      expect(security.restriction_level("\u30AB\u30BF\u30AB\u30CA\u3068\u3072\u3089\u304C\u306A\u3068\u6F22\u5B57")).to eq(:highly_restrictive)
    end

    it 'is moderately_restrictive for Latin mixed with one other recommended script' do
      expect(security.restriction_level("p\u0430ypal")).to eq(:moderately_restrictive)
    end

    it 'is minimally_restrictive for mixtures of recommended scripts' do
      expect(security.restriction_level("\u043F\u0440\u0438\u0432\u0435\u0442\u03B1\u03B2\u03B3")).to eq(:minimally_restrictive)
    end

    it 'is unrestricted for scripts outside the recommended set' do
      # Old Italic is a Limited Use script (neither Recommended nor
      # Aspirational), so mixing it with Latin is unrestricted.
      expect(security.restriction_level("\u{10300}")).to eq(:highly_restrictive)
      expect(security.restriction_level("a\u{10300}")).to eq(:unrestricted)
    end
  end

  describe '#check' do
    context 'with a normal Japanese mixed-script name' do
      let(:result) { security.check("\u5C71\u7530\u30BF\u30ED\u3042\u308A\u304C\u3068\u3046") }

      it 'is considered safe' do
        expect(result.safe?).to be(true)
        expect(result.reasons).to be_empty
      end

      it 'reports the Han/Hiragana/Katakana script set' do
        expect(result.scripts).to eq(Set['Han', 'Hiragana', 'Katakana'])
      end

      it 'is highly restrictive' do
        expect(result.restriction_level).to eq(:highly_restrictive)
      end
    end

    context 'with a normal single-script non-Latin name' do
      it 'is considered safe' do
        result = security.check("\u0434\u043C\u0438\u0442\u0440\u0438\u0439")
        expect(result.safe?).to be(true)
        expect(result.scripts).to eq(Set['Cyrillic'])
        expect(result.restriction_level).to eq(:highly_restrictive)
      end
    end

    context 'with a cross-script spoof' do
      let(:result) { security.check("p\u0430ypal") }

      it 'is not considered safe' do
        expect(result.safe?).to be(false)
      end

      it 'reports the mixed_scripts reason with the offending code points' do
        reason = result.reasons.find { |r| r.code == :mixed_scripts }
        expect(reason).not_to be_nil
        expect(reason.scripts).to eq(%w[Cyrillic Latin])
        expect(reason.code_points['Cyrillic']).to eq([0x0430])
        expect(reason.code_points['Latin']).to eq('pypal'.codepoints)
      end

      it 'keeps the skeleton and restriction level alongside the reasons' do
        expect(result.skeleton).to eq('paypal')
        expect(result.restriction_level).to eq(:moderately_restrictive)
      end
    end

    context 'with a plain ASCII name' do
      it 'is considered safe' do
        result = security.check('paypal')
        expect(result.safe?).to be(true)
        expect(result.skeleton).to eq('paypal')
        expect(result.restriction_level).to eq(:ascii_only)
      end
    end
  end

  describe '#compare' do
    context 'with two visually identical cross-script names' do
      let(:comparison) { security.compare('paypal', "p\u0430ypal") }

      it 'is confusable' do
        expect(comparison.confusable?).to be(true)
        expect(comparison.reasons.map(&:code)).to eq([:skeleton_match])
      end

      it 'keeps a full result for each side' do
        expect(comparison.first.skeleton).to eq('paypal')
        expect(comparison.first.restriction_level).to eq(:ascii_only)
        expect(comparison.first.safe?).to be(true)

        expect(comparison.second.skeleton).to eq('paypal')
        expect(comparison.second.restriction_level).to eq(:moderately_restrictive)
        expect(comparison.second.safe?).to be(false)
      end
    end

    context 'with two names that differ only in case' do
      let(:comparison) { security.compare('John', 'john') }

      it 'is not confusable (skeletons are case-sensitive)' do
        expect(comparison.confusable?).to be(false)
      end

      it 'is flagged as a case-only difference' do
        expect(comparison.case_only_difference?).to be(true)
        expect(comparison.reasons.map(&:code)).to eq([:case_only_difference])
      end

      it 'keeps distinct skeletons for each side' do
        expect(comparison.first.skeleton).to eq('John')
        expect(comparison.second.skeleton).to eq('john')
        expect(comparison.first.safe?).to be(true)
        expect(comparison.second.safe?).to be(true)
      end
    end

    context 'with identical names' do
      it 'is identical' do
        comparison = security.compare('alice', 'alice')
        expect(comparison.identical?).to be(true)
        expect(comparison.confusable?).to be(false)
      end
    end

    context 'with distinct names' do
      it 'is neither confusable nor a case-only difference' do
        comparison = security.compare('alice', 'bob')
        expect(comparison.confusable?).to be(false)
        expect(comparison.case_only_difference?).to be(false)
        expect(comparison.reasons.map(&:code)).to eq([:distinct])
      end
    end
  end

  describe '#confusable?' do
    it 'is true for cross-script lookalikes' do
      expect(security.confusable?('paypal', "p\u0430ypal")).to be(true)
    end

    it 'is false for names that differ only in case' do
      expect(security.confusable?('John', 'john')).to be(false)
    end

    it 'is false for distinct names' do
      expect(security.confusable?('alice', 'bob')).to be(false)
    end
  end
end
