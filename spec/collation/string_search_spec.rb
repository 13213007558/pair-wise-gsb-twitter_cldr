# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Collation::StringSearch do

  def search(string, substring, locale: nil, strength: :primary)
    described_class.new(locale, strength: strength).search(string, substring)
  end

  describe '#initialize' do
    it 'defaults to tertiary strength' do
      expect(described_class.new.strength).to eq(:tertiary)
    end

    it 'rejects invalid strengths' do
      expect { described_class.new(nil, strength: :quaternary) }.to raise_error(ArgumentError)
    end
  end

  describe '#search' do
    it 'returns a half-open character range for exact matches' do
      range = search('hello world', 'world', strength: :tertiary)
      expect(range).to eq(6...11)
      expect('hello world'[range]).to eq('world')
    end

    it 'returns nil when there is no match' do
      expect(search('hello', 'bye')).to be_nil
    end

    it 'returns nil when the needle is longer than the haystack' do
      expect(search('hi', 'hi there')).to be_nil
    end

    it 'matches an empty substring at the beginning of the string' do
      expect(search('hello', '')).to eq(0...0)
    end

    it 'returns nil when the substring has no significant weight at the given strength' do
      expect(search('hello', "\u00AD")).to be_nil
    end
  end

  describe 'collation strength' do
    it 'ignores accents at primary strength' do
      range = search('My résumé is ready', 'resume')
      expect('My résumé is ready'[range]).to eq('résumé')
    end

    it 'ignores case at primary strength' do
      range = search('Hello world', 'hello')
      expect('Hello world'[range]).to eq('Hello')
    end

    it 'distinguishes accents at secondary strength' do
      expect(search('résumé', 'resume', strength: :secondary)).to be_nil

      range = search('résumé', 'résumé', strength: :secondary)
      expect(range).to eq(0...6)
    end

    it 'ignores case at secondary strength' do
      range = search('Hello world', 'hello', strength: :secondary)
      expect('Hello world'[range]).to eq('Hello')
    end

    it 'distinguishes case at tertiary strength' do
      expect(search('Hello world', 'hello', strength: :tertiary)).to be_nil
    end
  end

  describe 'Unicode representations of accents' do
    let(:precomposed) { "Caf\u00e9" }       # é as a single code point
    let(:decomposed)  { "Cafe\u0301" }     # e + combining acute accent

    it 'finds precomposed accents and returns a range that slices the original string' do
      range = search(precomposed, 'cafe')
      expect(range).to eq(0...4)
      expect(precomposed[range]).to eq(precomposed)
    end

    it 'finds decomposed accents and returns a range that slices the original string' do
      range = search(decomposed, 'cafe')
      expect(range).to eq(0...5)
      expect(decomposed[range]).to eq(decomposed)
    end

    it 'finds both representations with a decomposed needle' do
      needle = "cafe\u0301"
      expect(precomposed[search(precomposed, needle)]).to eq(precomposed)
      expect(decomposed[search(decomposed, needle)]).to eq(decomposed)
    end
  end

  describe 'ignorable characters' do
    it 'does not break a match on fully ignorable characters' do
      string = "re\u00ADsume" # soft hyphen is fully ignorable
      range = search(string, 'resume')
      expect(range).to eq(0...7)
      expect(string[range]).to eq(string)
    end

    it 'absorbs trailing combining marks into the match at primary strength' do
      string = "cafe\u0301"
      range = search(string, 'cafe')
      expect(string[range]).to eq(string)
    end
  end

  describe 'expansions (one character, several collation elements)' do
    # In the root UCA, æ is an expansion equivalent to "ae".
    it 'matches the whole expanded character' do
      range = search('æsop', 'ae')
      expect(range).to eq(0...1)
      expect('æsop'[range]).to eq('æ')
    end

    it 'matches an expanded needle against separate characters' do
      range = search('aerie', 'æ')
      expect(range).to eq(0...2)
      expect('aerie'[range]).to eq('ae')
    end

    it 'does not allow matches to begin or end inside an expansion' do
      expect(search('æsop', 'a')).to be_nil
      expect(search('æsop', 'e')).to be_nil
    end
  end

  describe 'locale-specific contractions' do
    # In Slovak, "ch" is a single collation element.
    it 'matches contractions atomically' do
      range = search('chlieb', 'ch', locale: :sk)
      expect(range).to eq(0...2)
      expect('chlieb'[range]).to eq('ch')
    end

    it 'does not match parts of a contraction' do
      expect(search('chlieb', 'c', locale: :sk)).to be_nil
      expect(search('chlieb', 'h', locale: :sk)).to be_nil
    end

    it 'matches the same characters individually without the tailoring' do
      expect(search('chlieb', 'c')).to eq(0...1)
      expect(search('chlieb', 'h')).to eq(1...2)
    end

    # In Danish, "aa" is a contraction equivalent to "å".
    it 'matches a contraction against its equivalent character' do
      range = search('Aarhus', 'å', locale: :da)
      expect(range).to eq(0...2)
      expect('Aarhus'[range]).to eq('Aa')
    end

    it 'matches only the equivalent single character without the tailoring' do
      range = search('Aarhus', 'å')
      expect(range).to eq(0...1)
      expect('Aarhus'[range]).to eq('A')
    end
  end

  describe '#match?' do
    it 'returns true when the substring is found' do
      searcher = described_class.new(nil, strength: :primary)
      expect(searcher.match?('résumé', 'resume')).to be(true)
    end

    it 'returns false when the substring is not found' do
      searcher = described_class.new(nil, strength: :tertiary)
      expect(searcher.match?('résumé', 'resume')).to be(false)
    end
  end

end
