# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Collation::SubstringSearcher do

  let(:default_searcher) { described_class.new(strength: :primary) }

  describe '#initialize' do
    it 'uses tertiary strength by default' do
      expect(described_class.new.strength).to eq(:tertiary)
    end

    it 'accepts a locale' do
      expect(described_class.new(locale: :cs).locale).to eq(:cs)
    end

    it 'raises an ArgumentError for an invalid strength' do
      expect { described_class.new(strength: :quaternary) }.to raise_error(ArgumentError)
    end
  end

  describe '#search' do
    it 'returns a half-open character range of the first match in the original string' do
      expect(default_searcher.search('one café two', 'cafe')).to eq(4...8)
    end

    it 'returns nil when there is no match' do
      expect(default_searcher.search('abc', 'd')).to be_nil
    end

    it 'returns nil for an empty haystack or an empty needle' do
      expect(default_searcher.search('', 'a')).to be_nil
      expect(default_searcher.search('abc', '')).to be_nil
    end

    it 'returns nil when the needle has no significant weight at the given strength' do
      # a lone combining accent is ignorable at primary strength
      expect(default_searcher.search('abc', "\u0301")).to be_nil
    end

    it 'computes offsets in characters, not bytes' do
      haystack = "\u{1F600}café \u{1F600}CAFE"

      expect(default_searcher.find_all(haystack, 'cafe')).to eq([1...5, 7...11])
      expect(haystack[1...5]).to eq('café')
      expect(haystack[7...11]).to eq('CAFE')
    end
  end

  describe '#find_all' do
    it 'returns ranges of all non-overlapping matches' do
      expect(default_searcher.find_all('aaaa', 'aa')).to eq([0...2, 2...4])
    end

    it 'returns an empty array when there is no match' do
      expect(default_searcher.find_all('abc', 'd')).to eq([])
    end
  end

  describe 'matching at primary strength' do
    let(:searcher) { described_class.new(locale: :en, strength: :primary) }

    it 'ignores accents and case' do
      expect(searcher.search('résumé', 'RESUME')).to eq(0...6)
    end

    it 'returns a range that slices the corresponding substring of the original string' do
      haystack = 'Le résumé parfait'
      range    = searcher.search(haystack, 'resume')

      expect(haystack[range]).to eq('résumé')
    end

    context 'with accents in composed (NFC) and decomposed (NFD) forms' do
      let(:nfc) { "r\u00E9sum\u00E9" }       # 'résumé' with precomposed é
      let(:nfd) { "re\u0301sume\u0301" }     # 'résumé' with combining accents

      it 'finds matches regardless of the normalization form of the haystack' do
        expect(searcher.search(nfc, 'resume')).to eq(0...6)
        expect(searcher.search(nfd, 'resume')).to eq(0...8)
      end

      it 'finds matches regardless of the normalization form of the needle' do
        expect(searcher.search('café', "cafe\u0301")).to eq(0...4)
        expect(searcher.search("cafe\u0301", 'café')).to eq(0...5)
      end

      it 'returns ranges that slice the original (not normalized) text' do
        expect(nfc[searcher.search(nfc, 'resume')]).to eq(nfc)
        expect(nfd[searcher.search(nfd, 'resume')]).to eq(nfd)
      end

      it 'includes trailing ignorable characters in the match' do
        # the combining accent of the final 'é' is part of the match range
        expect(nfd[searcher.search(nfd, 'resume')]).to eq("re\u0301sume\u0301")
      end
    end
  end

  describe 'matching at secondary strength' do
    let(:searcher) { described_class.new(locale: :en, strength: :secondary) }

    it 'distinguishes accents' do
      expect(searcher.search('résumé', 'resume')).to be_nil
      expect(searcher.search('résumé', 'résumé')).to eq(0...6)
    end

    it 'still ignores case' do
      expect(searcher.search('Résumé', 'résumé')).to eq(0...6)
    end
  end

  describe 'matching at tertiary strength' do
    let(:searcher) { described_class.new(locale: :en, strength: :tertiary) }

    it 'distinguishes case' do
      expect(searcher.search('Résumé', 'résumé')).to be_nil
      expect(searcher.search('Résumé', 'Résumé')).to eq(0...6)
    end

    it 'matches canonically equivalent strings' do
      expect(searcher.search('café', "cafe\u0301")).to eq(0...4)
    end
  end

  describe 'expansions (one character producing several collation elements)' do
    # 'æ' collates like the sequence 'ae' in the root locale

    it 'finds multi-character needles inside an expansion' do
      expect(default_searcher.search('æther', 'ae')).to eq(0...1)
    end

    it 'allows matches inside an expansion and expands the range to the whole character' do
      # the match itself covers only the first collation element of 'æ', but the returned
      # range always covers the whole original character
      expect(default_searcher.search('æ', 'a')).to eq(0...1)
      expect('æther'[default_searcher.search('æther', 'a')]).to eq('æ')
    end

    it 'finds all matches when an expansion is involved' do
      expect(default_searcher.find_all('æther æon', 'ae')).to eq([0...1, 6...7])
    end
  end

  describe 'contractions (several characters producing a single collation element)' do
    # 'ch' is a single collation element in Czech
    let(:searcher) { described_class.new(locale: :cs, strength: :primary) }

    it 'finds needles that correspond to a whole contraction' do
      expect(searcher.search('chléb', 'ch')).to eq(0...2)
      expect(searcher.find_all('chch', 'ch')).to eq([0...2, 2...4])
    end

    it 'does not allow matches inside a contraction' do
      expect(searcher.search('ch', 'c')).to be_nil
      expect(searcher.search('ch', 'h')).to be_nil
    end

    it 'treats the same characters as separate elements in a locale without the contraction' do
      expect(default_searcher.search('ch', 'c')).to eq(0...1)
      expect(default_searcher.search('ch', 'h')).to eq(1...2)
    end
  end

  describe 'locale-specific equivalences' do
    # 'aa' collates like 'å' in Danish
    let(:searcher) { described_class.new(locale: :da, strength: :primary) }

    it 'matches locale-specific letter equivalents' do
      expect(searcher.search('Aarhus', 'aa')).to eq(0...2)
      expect(searcher.search('Aarhus', 'å')).to eq(0...2)
      expect('Aarhus'[searcher.search('Aarhus', 'å')]).to eq('Aa')
    end

    it 'distinguishes them at tertiary strength' do
      expect(described_class.new(locale: :da, strength: :tertiary).search('Aarhus', 'å')).to be_nil
    end
  end

end
