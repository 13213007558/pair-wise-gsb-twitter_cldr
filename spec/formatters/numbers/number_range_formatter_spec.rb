# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Formatters::NumberRangeFormatter do
  def format_range(left, right, options = {})
    reader_options = {}
    reader_options[:type] = options.delete(:type) if options.key?(:type)
    reader_options[:format] = options.delete(:format) if options.key?(:format)
    locale = options.delete(:locale) || :en

    TwitterCldr::DataReaders::NumberDataReader
      .new(locale, reader_options)
      .format_range(left, right, options)
  end

  def expect_spans_to_tile(result)
    offset = 0

    result.spans.each do |span|
      expect(span.start).to eq(offset)
      expect(span.slice(result.text)).to be_a(String)
      offset += span.length
    end

    expect(offset).to eq(result.text.length)
    expect(result.segments.map(&:last).join).to eq(result.text)
  end

  describe 'decimal ranges' do
    it 'formats a simple range with left/separator/right spans' do
      result = format_range(1, 3)

      expect(result.text).to eq("1–3")
      expect(result.kind).to eq(:range)
      expect(result.segments).to eq([[:left, "1"], [:shared, "–"], [:right, "3"]])
      expect_spans_to_tile(result)
    end

    it 'applies the same precision to both ends' do
      result = format_range(1.5, 2)

      expect(result.text).to eq("1.5–2.0")
      expect_spans_to_tile(result)
    end

    it 'respects an explicit precision option' do
      result = format_range(1.5, 2.75, precision: 1)

      expect(result.text).to eq("1.5–2.8")
      expect_spans_to_tile(result)
    end

    it 'does not collapse anything when signs differ' do
      result = format_range(-1, 2)

      expect(result.text).to eq("-1–2")
      expect(result.segments).to eq([[:left, "-1"], [:shared, "–"], [:right, "2"]])
      expect_spans_to_tile(result)
    end

    it 'does not collapse the minus sign when both ends are negative' do
      result = format_range(-2, -1)

      expect(result.text).to eq("-2–-1")
      expect(result.segments).to eq([[:left, "-2"], [:shared, "–"], [:right, "-1"]])
      expect_spans_to_tile(result)
    end
  end

  describe 'identity fallback' do
    it 'formats equal values as a single exact value' do
      result = format_range(2, 2)

      expect(result.text).to eq("2")
      expect(result.kind).to eq(:single)
      expect(result.segments).to eq([[:shared, "2"]])
      expect_spans_to_tile(result)
    end

    it 'treats -0.0 and 0.0 as the same single value' do
      result = format_range(-0.0, 0.0)

      expect(result.text).to eq("0.0")
      expect(result.kind).to eq(:single)
      expect_spans_to_tile(result)
    end

    it 'formats values that differ but display alike as an approximate value' do
      result = format_range(1.01, 1.02, precision: 1)

      expect(result.text).to eq("~1.0")
      expect(result.kind).to eq(:approximate)
      expect(result.segments).to eq([[:shared, "~1.0"]])
      expect_spans_to_tile(result)
    end

    it 'formats compact values that display alike as an approximate value' do
      result = format_range(1000, 1400, format: :short)

      expect(result.text).to eq("~1K")
      expect(result.kind).to eq(:approximate)
      expect_spans_to_tile(result)
    end
  end

  describe 'special values' do
    it 'formats a range ending at infinity' do
      result = format_range(5, Float::INFINITY)

      expect(result.text).to eq("5–∞")
      expect(result.kind).to eq(:range)
      expect(result.segments).to eq([[:left, "5"], [:shared, "–"], [:right, "∞"]])
      expect_spans_to_tile(result)
    end

    it 'formats a range from negative to positive infinity' do
      result = format_range(-Float::INFINITY, Float::INFINITY)

      expect(result.text).to eq("-∞–∞")
      expect_spans_to_tile(result)
    end

    it 'formats identical infinities as a single value' do
      result = format_range(Float::INFINITY, Float::INFINITY)

      expect(result.text).to eq("∞")
      expect(result.kind).to eq(:single)
      expect_spans_to_tile(result)
    end

    it 'formats NaN ends in a defined way' do
      result = format_range(Float::NAN, Float::NAN)

      expect(result.text).to eq("~NaN")
      expect(result.kind).to eq(:approximate)
      expect_spans_to_tile(result)
    end
  end

  describe 'percent ranges' do
    it 'collapses the shared percent sign' do
      result = format_range(1, 3, type: :percent)

      expect(result.text).to eq("1–3%")
      expect(result.segments).to eq([
        [:left, "1"], [:shared, "–"], [:right, "3"], [:shared, "%"]
      ])
      expect_spans_to_tile(result)
    end

    it 'keeps both minus signs when both ends are negative' do
      result = format_range(-3, -1, type: :percent)

      expect(result.text).to eq("-3–-1%")
      expect_spans_to_tile(result)
    end
  end

  describe 'currency ranges' do
    it 'collapses the shared currency symbol' do
      result = format_range(1, 2, type: :currency)

      expect(result.text).to eq("$1.00–2.00")
      expect(result.segments).to eq([
        [:shared, "$"], [:left, "1.00"], [:shared, "–"], [:right, "2.00"]
      ])
      expect_spans_to_tile(result)
    end

    it 'does not collapse currency symbols when signs differ' do
      result = format_range(-1, 2, type: :currency)

      expect(result.text).to eq("-$1.00–$2.00")
      expect_spans_to_tile(result)
    end

    it 'does not collapse the minus sign when both ends are negative' do
      result = format_range(-2, -1, type: :currency)

      expect(result.text).to eq("-$2.00–-$1.00")
      expect_spans_to_tile(result)
    end

    it 'collapses a shared compact magnitude' do
      result = format_range(1000, 2000, type: :currency, format: :short)

      expect(result.text).to eq("$1.00–2.00K")
      expect(result.segments).to eq([
        [:shared, "$"], [:left, "1.00"], [:shared, "–"], [:right, "2.00"], [:shared, "K"]
      ])
      expect_spans_to_tile(result)
    end

    it 'does not merge different magnitudes' do
      result = format_range(1000, 2_000_000, type: :currency, format: :short)

      expect(result.text).to eq("$1.00K–2.00M")
      expect(result.segments).to eq([
        [:shared, "$"], [:left, "1.00K"], [:shared, "–"], [:right, "2.00M"]
      ])
      expect_spans_to_tile(result)
    end

    it 'respects an explicit currency' do
      result = format_range(1, 2, type: :currency, currency: 'EUR')

      expect(result.text).to eq("€1.00–2.00")
      expect_spans_to_tile(result)
    end
  end

  describe 'compact decimal ranges' do
    it 'collapses a shared magnitude suffix' do
      result = format_range(1000, 2000, format: :short)

      expect(result.text).to eq("1–2K")
      expect_spans_to_tile(result)
    end

    it 'does not merge different magnitudes' do
      result = format_range(1000, 2_000_000, format: :short)

      expect(result.text).to eq("1K–2M")
      expect_spans_to_tile(result)
    end
  end

  describe 'locale fallback' do
    it 'falls back to root patterns for locales without their own' do
      result = format_range(1.01, 1.02, precision: 1, locale: :fr)

      expect(result.text).to eq("~1,0")
      expect(result.kind).to eq(:approximate)
      expect_spans_to_tile(result)
    end

    it 'uses the locale-specific approximately pattern when available' do
      expect(format_range(1.01, 1.02, precision: 1, locale: :zh).text).to eq("约1.0")
      expect(format_range(1.01, 1.02, precision: 1, locale: :'zh-Hant').text).to eq("約1.0")
      expect(format_range(1.01, 1.02, precision: 1, locale: :ja).text).to eq("約1.0")
    end
  end

  describe 'plural range rules' do
    it 'returns the CLDR range category when a rule exists' do
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:one, :other, :ro)).to eq(:few)
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:one, :other, :sl)).to eq(:few)
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:two, :other, :sl)).to eq(:few)
    end

    it 'falls back to the end category when no rule matches' do
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:one, :other, :en)).to eq(:other)
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:few, :other, :sl)).to eq(:other)
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:one, :few, :ro)).to eq(:few)
    end

    it 'returns the shared category when both ends are equal' do
      expect(TwitterCldr::Formatters::Plurals::RangeRules.rule_for(:one, :one, :ro)).to eq(:one)
    end

    it 'is used to select the pattern when both ends share a magnitude' do
      reader = TwitterCldr::DataReaders::NumberDataReader.new(:en, format: :short)

      expect(reader.pattern(1000, true, :one)).to include('K')
    end
  end
end
