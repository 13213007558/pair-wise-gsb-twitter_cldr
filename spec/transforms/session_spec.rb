# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Transforms::Session do
  def build_rule_set(*rule_texts)
    rules = TwitterCldr::Transforms::Transformer.send(
      :parse_rules, rule_texts.flatten
    )

    TwitterCldr::Transforms::Transformer.new(
      rules, :forward, nil
    ).forward_rule_set
  end

  def incremental_transform(rule_set, chunks, **options)
    session = rule_set.session(**options)
    output = +''
    chunks.each { |chunk| output << session.push(chunk) }
    output << session.finish
  end

  # splitting the input at every possible position must produce exactly
  # the same output as a one-shot transform
  def expect_split_consistency(rule_set, string)
    expected = rule_set.transform(string)

    (0..string.size).each do |split|
      chunks = [string[0...split], string[split..-1] || '']
      actual = incremental_transform(rule_set, chunks)

      expect(actual).to eq(expected),
        "expected #{chunks.inspect} to transform to #{expected.inspect} " \
        "but got #{actual.inspect} (split at #{split})"
    end
  end

  describe 'split consistency with one-shot transforms' do
    it 'handles before and after contexts' do
      rule_set = build_rule_set('x { a } b > y;')
      expect_split_consistency(rule_set, 'xab')
      expect_split_consistency(rule_set, 'xabc')
      expect_split_consistency(rule_set, 'xxabx')
      expect_split_consistency(rule_set, 'xax')
    end

    it 'handles rules that only need after-context' do
      rule_set = build_rule_set('{ a } b > x;')
      expect_split_consistency(rule_set, 'ab')
      expect_split_consistency(rule_set, 'acab')
      expect_split_consistency(rule_set, 'aa')
    end

    it 'handles capture replacement' do
      rule_set = build_rule_set('(a)(b) > $2$1;')
      expect_split_consistency(rule_set, 'abpqab')
    end

    it 'handles cursor movement' do
      rule_set = build_rule_set('ab > |x;')
      expect_split_consistency(rule_set, 'abab')

      rule_set = build_rule_set('ab > x|y;')
      expect_split_consistency(rule_set, 'abab')
    end

    it 'handles filters' do
      rule_set = build_rule_set(':: [ab];', 'a > x;')
      expect_split_consistency(rule_set, 'abaaca')
    end

    it 'handles multiple conversion rule sets in a row' do
      rule_set = build_rule_set('a > b;', ':: [x];', 'c > d;')
      expect_split_consistency(rule_set, 'acac')
    end

    it 'handles unbounded keys' do
      rule_set = build_rule_set("a+ > 'X';")
      expect_split_consistency(rule_set, 'aaabaa')
    end

    it 'handles negated after-contexts that match at the end of the text' do
      rule_set = build_rule_set('{ a } [^b] > x;')
      expect_split_consistency(rule_set, 'a')
      expect_split_consistency(rule_set, 'ac')
      expect_split_consistency(rule_set, 'ab')
    end

    it 'handles normalization and casing transforms' do
      rule_set = build_rule_set(':: NFD;', ':: NFC;')
      expect_split_consistency(rule_set, "éx̀")

      rule_set = build_rule_set(':: Lower;', 'b > x;')
      expect_split_consistency(rule_set, 'ABab')
    end

    it 'handles more than two chunks' do
      rule_set = build_rule_set('x { a } b > y;', '(p)(q) > $2$1;')
      string = 'xabpq'
      expected = rule_set.transform(string)

      (0..string.size).each do |first|
        (first..string.size).each do |second|
          chunks = [
            string[0...first],
            string[first...second],
            string[second..-1] || ''
          ]

          expect(incremental_transform(rule_set, chunks)).to eq(expected)
        end
      end
    end

    it 'matches one-shot results for a real transformer' do
      rule_set = TwitterCldr::Transforms::Transformer.get('Cyrillic-Latin')
      expect_split_consistency(rule_set, 'Привет, мир!')
    end
  end

  describe 'holding back undecided output' do
    let(:rule_set) { build_rule_set('{ a } b > x;') }

    it 'does not emit irrevocable output while an after-context is missing' do
      session = rule_set.session
      expect(session.push('a')).to eq('')
      expect(session.push('c')).to eq('ac')
      expect(session.finish).to eq('')
    end

    it 'applies the rule once the after-context arrives' do
      session = rule_set.session
      expect(session.push('a')).to eq('')
      expect(session.push('b')).to eq('xb')
      expect(session.finish).to eq('')
    end

    it 'treats the end of the text as real only after finish' do
      session = rule_set.session
      expect(session.push('a')).to eq('')
      expect(session.finish).to eq('a')
    end

    it 'applies negated after-contexts at the true end of the text' do
      rule_set = build_rule_set('{ a } [^b] > x;')
      session = rule_set.session
      expect(session.push('a')).to eq('')
      expect(session.finish).to eq('x')
    end

    it 'commits text that no rule can still touch' do
      session = rule_set.session
      expect(session.push('ca')).to eq('c')
      expect(session.finish).to eq('a')
    end
  end

  describe 'pending limit' do
    let(:rule_set) { build_rule_set('a+ > x;') }

    it 'raises an error naming the responsible rule when exceeded' do
      session = rule_set.session(max_pending: 4)
      expect(session.push('aaaa')).to eq('')

      expect { session.push('a') }.to raise_error(
        TwitterCldr::Transforms::PendingLimitExceededError,
        /a\+ > x;/
      )
    end

    it 'exposes the responsible rule' do
      session = rule_set.session(max_pending: 2)

      begin
        session.push('aaaa')
        raise 'expected PendingLimitExceededError'
      rescue TwitterCldr::Transforms::PendingLimitExceededError => e
        expect(e.rule.original_rule_text).to eq('a+ > x;')
        expect(e.limit).to eq(2)
      end
    end

    it 'stays usable after the error and never emits wrong output' do
      session = rule_set.session(max_pending: 2)
      session.push('aa') rescue nil
      expect { session.push('aa') }.to raise_error(
        TwitterCldr::Transforms::PendingLimitExceededError
      )

      # finishing decides the held-back text for real
      expect(session.finish).to eq('x')
    end
  end

  describe 'session independence' do
    it 'shares the rule set but not cursor or pending text' do
      rule_set = build_rule_set('{ a } b > x;')
      first = rule_set.session
      second = rule_set.session

      expect(first.push('a')).to eq('')
      expect(second.push('ab')).to eq('xb')
      expect(first.push('b')).to eq('xb')
      expect(first.finish).to eq('')
      expect(second.finish).to eq('')
    end

    it 'leaves the shared rule set usable for one-shot transforms' do
      rule_set = build_rule_set('{ a } b > x;')
      session = rule_set.session
      session.push('ab')
      session.finish

      expect(rule_set.transform('ab')).to eq('xb')
    end
  end

  describe 'stream lifecycle' do
    it 'raises when pushing into a finished session' do
      session = build_rule_set('a > b;').session
      session.finish

      expect { session.push('a') }.to raise_error(
        TwitterCldr::Transforms::SessionFinishedError
      )
    end

    it 'returns an empty string when finishing twice' do
      session = build_rule_set('a > b;').session
      expect(session.push('a')).to eq('b')
      expect(session.finish).to eq('')
      expect(session.finish).to eq('')
    end

    it 'acts as the identity for an empty rule set' do
      session = TwitterCldr::Transforms::RuleSet.new([], nil).session
      expect(session.push('abc')).to eq('abc')
      expect(session.finish).to eq('')
    end
  end
end
