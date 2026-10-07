# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters

    # Formats a range of two numbers (decimal, percent, or currency) as a
    # single string, collapsing shared affixes (currency symbols, percent
    # signs, compact magnitude suffixes) when - and only when - they are
    # semantically identical on both ends. Returns a NumberRange that
    # reports the provenance (:left, :right, or :shared) of every segment
    # of the final text.
    class NumberRangeFormatter

      DEFAULT_RANGE_PATTERN = "{0}–{1}"
      DEFAULT_APPROXIMATELY_PATTERN = "~{0}"

      attr_reader :data_reader

      def initialize(data_reader)
        @data_reader = data_reader
      end

      def format_range(left, right, options = {})
        options = options.dup
        options[:locale] = data_reader.locale
        formatter.prepare_range_options(left, right, options)

        left_tokens, right_tokens = tokens_for_range(left, right, options)
        left_parts = formatter.format_parts(left_tokens, left, options)
        right_parts = formatter.format_parts(right_tokens, right, options)

        if left_parts.text == right_parts.text
          identity_result(left, right, left_parts)
        else
          range_result(left, right, left_parts, right_parts)
        end
      end

      private

      def formatter
        data_reader.formatter
      end

      # Both ends are formatted with the same precision/rounding options.
      # When both ends share the same (compact) magnitude, the pattern is
      # chosen with the CLDR plural range category of the range as a whole;
      # otherwise each end uses its own plural category.
      def tokens_for_range(left, right, options)
        decimal = (options[:precision] || 0) == 0
        plural_rule = range_plural_rule(left, right, decimal)

        [left, right].map do |number|
          pattern = data_reader.pattern(pattern_number(number), decimal, plural_rule)
          data_reader.tokenizer.tokenize(pattern)
        end
      end

      # Infinity and NaN have no meaningful magnitude, so their pattern is
      # derived from a finite stand-in with the same sign.
      def pattern_number(number)
        return number unless formatter.special_number?(number)
        return 1 if number.respond_to?(:nan?) && number.nan?

        number < 0 ? -1 : 1
      end

      def range_plural_rule(left, right, decimal)
        return nil if formatter.special_number?(left) || formatter.special_number?(right)
        return nil unless magnitude_of(left) == magnitude_of(right)

        Plurals::RangeRules.rule_for(
          data_reader.plural_rule_for(left, decimal),
          data_reader.plural_rule_for(right, decimal),
          data_reader.locale
        )
      end

      def magnitude_of(number)
        "1#{'0' * (number.to_i.abs.to_s.size - 1)}"
      end

      # Both ends produced the same text. If the original values are also
      # equal, the result is a single exact value; otherwise it is a single
      # approximate value (the ends differ but round to the same display).
      def identity_result(left, right, parts)
        if left == right
          NumberRange.new(parts.text, [[parts.text, :shared]], :single)
        else
          pre, post = split_placeholder(approximately_pattern, "{0}")

          segments = [
            [pre, :shared],
            [parts.prefix, :shared],
            [parts.number, :shared],
            [parts.suffix, :shared],
            [post, :shared]
          ]

          NumberRange.new("#{pre}#{parts.text}#{post}", segments, :approximate)
        end
      end

      def range_result(left, right, left_parts, right_parts)
        pre, separator, post = split_range_pattern(range_pattern)
        same_sign = sign_of(left) == sign_of(right)

        shared_prefix = if same_sign &&
            !left_parts.prefix.empty? &&
            left_parts.prefix == right_parts.prefix &&
            !sign_affix?(left_parts.prefix)
          left_parts.prefix
        end

        shared_suffix = if same_sign &&
            !left_parts.suffix.empty? &&
            left_parts.suffix == right_parts.suffix &&
            !sign_affix?(left_parts.suffix)
          left_parts.suffix
        end

        segments = [
          [pre, :shared],
          [shared_prefix || left_parts.prefix, shared_prefix ? :shared : :left],
          [left_parts.number, :left],
          (shared_suffix ? nil : [left_parts.suffix, :left]),
          [separator, :shared],
          (shared_prefix ? nil : [right_parts.prefix, :right]),
          [right_parts.number, :right],
          [right_parts.suffix, shared_suffix ? :shared : :right],
          [post, :shared]
        ].compact

        NumberRange.new(segments.map(&:first).join, segments, :range)
      end

      def sign_of(number)
        negative = if number.respond_to?(:nan?) && number.nan?
          false
        else
          number < 0
        end

        negative ? :negative : :positive
      end

      def sign_affix?(text)
        text.include?(minus_sign) || text.include?(plus_sign)
      end

      def minus_sign
        data_reader.symbols[:minus_sign] || "-"
      end

      def plus_sign
        data_reader.symbols[:plus_sign] || "+"
      end

      def range_pattern
        pattern = range_pattern_for(:range)
        valid_range_pattern?(pattern) ? pattern : DEFAULT_RANGE_PATTERN
      end

      def approximately_pattern
        pattern = range_pattern_for(:approximately)
        pattern && pattern.include?("{0}") ? pattern : DEFAULT_APPROXIMATELY_PATTERN
      end

      # Looks up a range pattern key, walking the locale fallback chain
      # (e.g. zh-Hant -> zh -> root) until a value is found.
      def range_pattern_for(key)
        @range_pattern_cache ||= {}

        unless @range_pattern_cache.key?(key)
          resource = TwitterCldr.get_resource(:shared, :number_range_patterns)

          @range_pattern_cache[key] = locale_candidates.lazy.map do |candidate|
            entry = resource[candidate] || resource[candidate.to_s]
            entry[key] if entry
          end.find { |value| value }
        end

        @range_pattern_cache[key]
      end

      def locale_candidates
        parsed = TwitterCldr::Shared::Locale.parse(
          TwitterCldr.convert_locale(data_reader.locale).to_s.tr("_", "-")
        )

        (parsed.permutations("-").map(&:to_sym) + [:root]).uniq
      end

      def split_range_pattern(pattern)
        pre, rest = pattern.split("{0}", 2)
        separator, post = rest.split("{1}", 2)
        [pre, separator, post]
      end

      def valid_range_pattern?(pattern)
        !pattern.nil? && pattern.include?("{0}") && pattern.include?("{1}")
      end

      def split_placeholder(pattern, placeholder)
        pattern.split(placeholder, 2)
      end

    end
  end
end
