# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Transforms::PartialRegexp do
  def compile(pattern)
    uregexp = TwitterCldr::Shared::UnicodeRegex.compile(pattern)
    [described_class.compile(uregexp.elements), uregexp.to_regexp]
  end

  def compile_anchored(pattern)
    partial, regexp = compile(pattern)
    [partial, Regexp.new("\A(?:#{regexp.source})")]
  end

  describe '#partial?' do
    it 'is false when the pattern can never match, whatever comes next' do
      partial, = compile('ab')
      expect(partial.partial?('x', 0)).to be(false)
      expect(partial.partial?('ax', 1)).to be(false)
    end

    it 'is true when the buffer is a prefix of a possible match' do
      partial, = compile('ab')
      expect(partial.partial?('a', 0)).to be(true)
    end

    it 'is false when the match is complete and cannot grow' do
      partial, = compile('ab')
      expect(partial.partial?('ab', 0)).to be(false)
    end

    it 'is true when an unbounded pattern reaches the end of the buffer' do
      partial, = compile('a+')
      expect(partial.partial?('aaa', 0)).to be(true)
      expect(partial.partial?('aab', 0)).to be(false)
    end

    it 'is true when a longer alternative could still win' do
      partial, = compile('(?:abc|a)')
      expect(partial.partial?('ab', 0)).to be(true)
      expect(partial.partial?('abc', 0)).to be(false)
    end

    it 'is true when an end-of-text assertion was used' do
      # this is the shape Side produces for negated character classes
      partial, = compile('(?:[^b]|\z)')
      expect(partial.partial?('a', 1)).to be(true)
      expect(partial.partial?('ab', 1)).to be(false)
    end

    it 'handles bounded repeats' do
      partial, = compile('a{2,3}')
      expect(partial.partial?('a', 0)).to be(true)
      expect(partial.partial?('aaa', 0)).to be(false)
    end

    it 'treats multi-digit repeat counts as literal text, like Ruby does' do
      # "{100}" is tokenized as a literal string (ICU multichar syntax),
      # so this behaves exactly like the pattern 'a100'
      partial, regexp = compile('a{100}')
      expect(regexp).to match('a100')
      expect(partial.partial?('a10', 0)).to be(true)
      expect(partial.partial?('a100', 0)).to be(false)
      expect(partial.partial?('a' * 50, 0)).to be(false)
    end

    it 'handles character classes and groups' do
      partial, = compile('[ab](?:c[de])+')
      expect(partial.partial?('ac', 0)).to be(true)
      expect(partial.partial?('acd', 0)).to be(true)
      expect(partial.partial?('acdx', 0)).to be(false)
    end

    it 'honors the starting position' do
      partial, = compile('ab')
      expect(partial.partial?('xa', 1)).to be(true)
      expect(partial.partial?('xab', 1)).to be(false)
    end
  end

  describe 'soundness against Ruby regexp' do
    # Whenever partial? is false, extending the buffer must not change the
    # anchored match outcome of the equivalent Ruby regexp.
    it 'never changes the match outcome when not partial' do
      atoms = ['a', 'b', '[ab]', '[^a]', '(?:ab|a)', '(?:a|b)+', 'a*', 'b?', 'a{1,2}', 'b{2}']
      prng = Random.new(1234)

      100.times do
        pattern = atoms.sample(1 + prng.rand(3), random: prng).join
        partial, regexp = compile_anchored(pattern)

        20.times do
          text = Array.new(prng.rand(0..5)) { 'abc'.chars.sample(random: prng) }.join
          next if partial.partial?(text, 0)

          baseline = regexp.match(text, 0)

          5.times do
            extension = Array.new(prng.rand(1..3)) { 'abc'.chars.sample(random: prng) }.join
            extended = regexp.match(text + extension, 0)

            if baseline.nil?
              expect(extended).to be_nil,
                "expected /#{pattern}/ to keep not matching #{text.inspect} " \
                "after appending #{extension.inspect}"
            else
              expect(extended).to_not be_nil
              expect([extended.begin(0), extended.end(0), extended.captures]).to(
                eq([baseline.begin(0), baseline.end(0), baseline.captures]),
                "expected /#{pattern}/ match on #{text.inspect} to stay " \
                "stable after appending #{extension.inspect}"
              )
            end
          end
        end
      end
    end
  end
end
