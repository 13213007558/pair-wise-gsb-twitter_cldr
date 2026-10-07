# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Formatters::NumberRangeFormatter do

  def range_for(left, right, locale, type, options = {})
    data_reader = TwitterCldr::DataReaders::NumberDataReader.new(
      locale, { type: type }.merge(options.slice(:format, :number_system))
    )
    data_reader.format_number_range(left, right, options)
  end

  def verify_fragments!(result)
    expect(result.fragments.map(&:text).join).to eq(result.text)
    result.fragments.each do |fragment|
      expect(result.text[fragment.start...fragment.end]).to eq(fragment.text)
      expect([:left, :right, :shared]).to include(fragment.source)
    end
  end

  describe 'plain numbers' do
    it 'formats an English range with an en dash and folds nothing else' do
      result = range_for(3, 5, :en, :decimal)
      expect(result).to be_range
      expect(result.text).to eq('3–5')
      verify_fragments!(result)
      sources = result.fragments.map(&:source)
      expect(sources).to eq([:left, :shared, :right])
    end

    it 'uses the locale-specific range separator' do
      result = range_for(3, 5, :fr, :decimal)
      expect(result.text).to eq('3 – 5')
      expect(result.fragments_for(:shared).map(&:text)).to eq([' – '])
      verify_fragments!(result)
    end

    it 'supports Japanese-style range patterns' do
      result = range_for(3, 5, :ja, :decimal)
      expect(result.text).to eq('3～5')
      verify_fragments!(result)
    end

    it 'falls back to a deterministic pattern when the locale has no range resource' do
      result = range_for(3, 5, :af, :decimal)
      expect(result.text).to eq('3–5')
      verify_fragments!(result)
    end

    it 'attributes a negative sign to the left endpoint' do
      result = range_for(-3, 5, :en, :decimal)
      expect(result.text).to eq('-3–5')
      expect(result.fragments_for(:left).map(&:text).join).to eq('-3')
      expect(result.fragments_for(:right).map(&:text).join).to eq('5')
      verify_fragments!(result)
    end

    it 'uses shared precision across both endpoints' do
      result = range_for(1.2, 1.36, :en, :decimal)
      expect(result.text).to eq('1.20–1.36')
      verify_fragments!(result)
    end

    it 'honors an explicit precision for both endpoints' do
      result = range_for(1, 2, :en, :decimal, precision: 2)
      expect(result.text).to eq('1.00–2.00')
      verify_fragments!(result)
    end

    it 'honors shared rounding' do
      result = range_for(1.02, 1.08, :en, :decimal, precision: 2, rounding: 5)
      expect(result.text).to eq('1.00–1.10')
      verify_fragments!(result)
    end
  end

  describe 'percentages' do
    it 'folds a shared percent sign' do
      result = range_for(0.3, 0.5, :en, :percent)
      expect(result.text).to eq('0.3–0.5%')
      shared = result.fragments_for(:shared).map(&:text)
      expect(shared).to include('%')
      expect(result.fragments_for(:left).map(&:text).join).to eq('0.3')
      expect(result.fragments_for(:right).map(&:text).join).to eq('0.5')
      verify_fragments!(result)
    end

    it 'uses shared precision' do
      result = range_for(0.3, 0.57, :en, :percent)
      expect(result.text).to eq('0.30–0.57%')
      verify_fragments!(result)
    end

    it 'does not fold percent signs when endpoints are signed differently' do
      result = range_for(-0.3, 0.5, :en, :percent)
      expect(result.text).to eq('-0.3–0.5%')
      expect(result.fragments_for(:left).map(&:text).join).to start_with('-')
      verify_fragments!(result)
    end
  end

  describe 'currencies' do
    it 'folds the shared currency symbol' do
      result = range_for(3, 5, :en, :currency)
      expect(result.text).to eq('$3.00–5.00')
      expect(result.fragments.first.source).to eq(:shared)
      expect(result.fragments.first.text).to eq('$')
      verify_fragments!(result)
    end

    it 'does not fold mismatched currency symbols' do
      result = range_for(3, 5, :en, :currency, symbol: '€')
      expect(result.text).to eq('€3.00–5.00')
      expect(result.fragments.first.text).to eq('€')
      verify_fragments!(result)
    end

    it 'uses currency-specific default precision for both endpoints' do
      result = range_for(3, 5, :en, :currency, currency: 'TND')
      expect(result.text).to eq('TND3.000–5.000')
      verify_fragments!(result)
    end

    it 'keeps the sign with the negative endpoint currency prefix' do
      result = range_for(-12, 5, :en, :currency)
      expect(result.text).to eq('-$12.00–$5.00')
      expect(result.fragments_for(:left).map(&:text).join).to eq('-$12.00')
      expect(result.fragments_for(:right).map(&:text).join).to eq('$5.00')
      verify_fragments!(result)
    end

    it 'keeps both minus signs when both endpoints are negative' do
      result = range_for(-5, -3, :en, :currency)
      expect(result.text).to eq('-$5.00–-$3.00')
      expect(result.fragments_for(:left).map(&:text).join).to eq('-$5.00')
      expect(result.fragments_for(:right).map(&:text).join).to eq('-$3.00')
      verify_fragments!(result)
    end
  end

  describe 'compact numbers' do
    it 'folds a shared compact magnitude' do
      result = range_for(3_000, 5_000, :en, :decimal, format: :short)
      expect(result.text).to eq('3–5K')
      shared = result.fragments_for(:shared).map(&:text)
      expect(shared).to include('K')
      verify_fragments!(result)
    end

    it 'does not fold differing magnitudes' do
      result = range_for(3_000, 5_000_000, :en, :decimal, format: :short)
      expect(result.text).to eq('3K–5M')
      expect(result.fragments_for(:left).map(&:text)).to include('K')
      expect(result.fragments_for(:right).map(&:text)).to include('M')
      verify_fragments!(result)
    end
  end

  describe 'single and approximate results' do
    it 'returns a single exact value for numerically equal endpoints' do
      result = range_for(3, 3, :en, :decimal)
      expect(result).to be_single
      expect(result.text).to eq('3')
      expect(result.fragments.map(&:source).uniq).to eq([:shared])
    end

    it 'treats positive and negative zero as the same number' do
      result = range_for(-0.0, 0.0, :en, :decimal, precision: 1)
      expect(result).to be_single
      expect(result.text).to eq('0.0')
    end

    it 'returns an approximate value when displays collapse' do
      result = range_for(1_400, 1_490, :en, :decimal, format: :short)
      expect(result).to be_approximate
      expect(result.text).to eq('~1K')
      expect(result.fragments.first.source).to eq(:shared)
      expect(result.fragments.first.text).to eq('~')
      verify_fragments!(result)
    end

    it 'uses the localized approximately sign' do
      result = range_for(1.46, 1.49, :en, :decimal, precision: 1)
      expect(result).to be_approximate
      expect(result.text).to eq('~1.5')
    end
  end

  describe 'special values' do
    it 'formats a range ending at infinity' do
      result = range_for(3, Float::INFINITY, :en, :decimal)
      expect(result.text).to eq('3–∞')
      verify_fragments!(result)
    end

    it 'formats a range starting at negative infinity' do
      result = range_for(-Float::INFINITY, 5, :en, :decimal)
      expect(result.text).to eq('-∞–5')
      verify_fragments!(result)
    end

    it 'supports BigDecimal endpoints' do
      result = range_for(BigDecimal('1.2'), BigDecimal('1.4'), :en, :decimal)
      expect(result.text).to eq('1.2–1.4')
      verify_fragments!(result)
    end

    it 'formats NaN using the locale NaN symbol' do
      result = range_for(1, Float::NAN, :en, :decimal)
      expect(result).to be_range
      expect(result.text).to eq('1–NaN')
      expect(result.fragments_for(:right).map(&:text).join).to eq('NaN')
      verify_fragments!(result)
    end
  end

  describe 'fragment provenance and offsets' do
    it 'reconstructs the text exactly and reports valid offsets' do
      result = range_for(1.2, 3.4, :fr, :decimal)
      expect(result.fragments.map(&:text).join).to eq(result.text)
      result.fragments.each do |fragment|
        expect(result.slice(fragment)).to eq(fragment.text)
        expect(fragment.end).to be >= fragment.start
      end
    end

    it 'records the formatted single endpoint texts' do
      result = range_for(3, 5, :en, :currency)
      expect(result.left_text).to eq('$3.00')
      expect(result.right_text).to eq('$5.00')
    end
  end

end
