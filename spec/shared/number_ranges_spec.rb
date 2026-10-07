# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Shared::NumberRanges do
  describe '.pattern_for' do
    it 'returns the locale range pattern for a type' do
      pattern = described_class.pattern_for(:en, :decimal, :one, :other)
      expect(pattern).to eq('{0}–{1}')
    end

    it 'uses the Japanese range separator' do
      pattern = described_class.pattern_for(:ja, :currency, :other, :other)
      expect(pattern).to eq('{0}～{1}')
    end

    it 'falls back through the locale ancestry to a parent locale' do
      pattern = described_class.pattern_for(:fr_CA, :decimal, :one, :other)
      expect(pattern).to eq('{0} – {1}')
    end

    it 'falls back to the root/default pattern when nothing matches' do
      pattern = described_class.pattern_for(:af, :decimal, :one, :few)
      expect(pattern).to eq('{0}–{1}')
    end

    it 'falls back to the other plural category for the left endpoint' do
      pattern = described_class.pattern_for(:en, :percent, :few, :other)
      expect(pattern).to eq('{0}–{1}')
    end
  end

  describe '.fallback_for' do
    it 'returns the type-specific locale pattern' do
      expect(described_class.fallback_for(:ja, :currency)).to eq('{0}～{1}')
    end

    it 'falls back deterministically for unsupported locales' do
      expect(described_class.fallback_for(:af, :decimal)).to eq('{0}–{1}')
    end
  end
end
