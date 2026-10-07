# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    class NumberFormatter < Formatter

      attr_reader :data_reader

      MAGNITUDE_LEADING = :leading
      MAGNITUDE_TRAILING = :trailing

      SPECIAL_MARKER_REGEX = /[¤%‰+\-]/.freeze

      def initialize(data_reader)
        @data_reader = data_reader
      end

      def format(tokens, number, options = {})
        options[:precision] ||= precision_from(number)
        options[:type] ||= :decimal

        parts = format_parts(tokens, number, options)
        number_system.transliterate(parts[:full])
      end

      # Formats +number+ into a hash of independently transliterated parts.
      #
      # The :prefix and :suffix are the (possibly sign-bearing, compact)
      # affixes of the resolved pattern with any folded compact magnitude
      # marker removed. :integer is always unsigned; any minus/plus sign
      # lives in the affix and is additionally reported as :sign for
      # convenience. :magnitude is the compact (short/long) marker, if any,
      # along with its :magnitude_position (:leading or :trailing).
      #
      #   { prefix:, sign:, integer:, fraction:, magnitude:,
      #     magnitude_position:, suffix:, number:, base:, full: }
      def format_parts(tokens, number, options = {})
        options[:precision] ||= precision_from(number)
        options[:type] ||= :decimal

        prefix_token, suffix_token, integer_format, fraction_format = *partition_tokens(tokens)
        magnitude, magnitude_position =
          compact_magnitude(prefix_token.to_s, suffix_token.to_s)

        if finite?(number)
          parts_for_finite(
            number, prefix_token, suffix_token, integer_format,
            fraction_format, magnitude, magnitude_position, options
          )
        else
          parts_for_non_finite(
            number, prefix_token, suffix_token, magnitude, magnitude_position
          )
        end
      end

      # Precision/rounding options shared by both range endpoints. Both
      # endpoints are rounded with a single precision so that, for example,
      # 1.2 and 1.3 render with matching fraction widths. Explicit options
      # always win.
      def shared_options(left, right, options = {})
        options = options.dup
        unless options.key?(:precision)
          options[:precision] = shared_precision(left, right)
        end
        options[:rounding] = 0 unless options.key?(:rounding)
        options[:type] ||= :decimal
        options
      end

      def truncate_number(number, decimal_digits)
        if abbreviate?(number)
          factor = [0, number.to_i.abs.to_s.length - decimal_digits].max
          number / (10.0 ** factor)
        else
          number
        end
      end

      protected

      def number_system
        @number_system ||= TwitterCldr::Shared::NumberingSystem.for_name(
          data_reader.number_system
        )
      end

      def partition_tokens(tokens)
        [
          token_val_from(tokens[0]),
          token_val_from(tokens[2]),
          Numbers::Integer.new(tokens[1], data_reader.symbols),
          Numbers::Fraction.new(tokens[1], data_reader.symbols)
        ]
      end

      def token_val_from(token)
        token ? token.value : ""
      end

      def parse_number(number, options = {})
        precision = options[:precision] || precision_from(number)
        rounding = options[:rounding] || 0

        if number.is_a? BigDecimal
          number = precision == 0 ?
            round_to(number, precision, rounding).abs.fix.to_s("F") :
            round_to(number, precision, rounding).abs.round(precision).to_s("F")
        else
          number = "%.#{precision}f" % round_to(number, precision, rounding).abs
        end
        number.split(".")
      end

      def round_to(number, precision, rounding = 0)
        factor = 10 ** precision
        result = number.is_a?(BigDecimal) ?
          ((number * factor).fix / factor) :
          ((number * factor).round.to_f / factor)

        if rounding > 0
          rounding = rounding.to_f / factor
          result = number.is_a?(BigDecimal) ?
            ((result *  (1.0 / rounding)).fix / (1.0 / rounding)) :
            ((result *  (1.0 / rounding)).round.to_f / (1.0 / rounding))
        end

        result
      end

      def precision_from(num)
        return 0 unless finite?(num)
        return 0 if num.is_a?(BigDecimal) && num.fix == num
        parts = (num.is_a?(BigDecimal) ? num.to_s("F") : num.to_s).split(".")
        parts.size == 2 ? parts[1].size : 0
      end

      def abbreviate?(number)
        return false unless finite?(number)
        TwitterCldr::DataReaders::NumberDataReader.within_abbreviation_range?(number) &&
          (data_reader.format == :short || data_reader.format == :long)
      end

      private

      def parts_for_finite(number, prefix_token, suffix_token, integer_format,
                            fraction_format, magnitude, magnitude_position, options)
        truncated = truncate_number(number, integer_format.format.length)
        int, fraction = parse_number(truncated, options)

        integer = number_system.transliterate(integer_format.apply(int, options))
        fraction_part = if fraction
          text = fraction_format.apply(fraction, options)
          text.empty? ? text : number_system.transliterate(text)
        else
          ''
        end

        prefix, suffix =
          affixes_without_magnitude(prefix_token.to_s, suffix_token.to_s,
                                   magnitude, magnitude_position)
        sign = finite_sign(number, prefix, suffix)

        build_parts(prefix, suffix, sign, integer, fraction_part,
                    magnitude, magnitude_position)
      end

      def parts_for_non_finite(number, prefix_token, suffix_token,
                               magnitude, magnitude_position)
        if number.respond_to?(:nan?) && number.nan?
          text = data_reader.symbols[:nan] || 'NaN'
          sign = ''
        else
          text = data_reader.symbols[:infinity] || '∞'
          sign = number.respond_to?(:negative?) && number.negative? ?
            (data_reader.symbols[:minus_sign] || '-') : ''
        end

        prefix, suffix =
          affixes_without_magnitude(prefix_token.to_s, suffix_token.to_s,
                                   magnitude, magnitude_position)

        # The sign is normally carried by the negative pattern's prefix; it
        # only has to be prepended when that pattern lacks a sign.
        prefix = "#{sign}#{prefix}" unless sign.empty? || affix_sign(prefix, suffix) == sign

        build_parts(prefix, suffix, sign, number_system.transliterate(text), '',
                    magnitude, magnitude_position)
      end

      def build_parts(prefix, suffix, sign, integer, fraction,
                      magnitude, magnitude_position)
        number_part = "#{integer}#{fraction}"
        base = if magnitude_position == MAGNITUDE_LEADING
          "#{magnitude}#{number_part}"
        else
          "#{number_part}#{magnitude}"
        end

        {
          prefix: prefix.to_s,
          sign: sign.to_s,
          integer: integer.to_s,
          fraction: fraction.to_s,
          magnitude: magnitude.to_s,
          magnitude_position: magnitude.nil? || magnitude.to_s.empty? ? nil : magnitude_position,
          suffix: suffix.to_s,
          number: number_part,
          base: base,
          full: "#{prefix}#{base}#{suffix}"
        }
      end

      # Locates the compact magnitude marker, if any, in either affix and
      # returns it together with its position. Standard (non-compact)
      # formats always return an empty marker. Fixed affix content such as
      # currency/percent symbols and signs is ignored.
      def compact_magnitude(prefix, suffix)
        return ['', nil] unless data_reader.format == :short || data_reader.format == :long

        leading = marker_in(prefix)
        return [leading, MAGNITUDE_LEADING] if leading

        trailing = marker_in(suffix)
        return [trailing, MAGNITUDE_TRAILING] if trailing

        ['', nil]
      end

      def marker_in(affix)
        return nil if affix.nil? || affix.empty?
        marker = affix.gsub(SPECIAL_MARKER_REGEX, '')
        marker.empty? ? nil : marker
      end

      def affixes_without_magnitude(prefix, suffix, magnitude, magnitude_position)
        return [prefix, suffix] if magnitude.nil? || magnitude.empty?

        if magnitude_position == MAGNITUDE_LEADING && prefix.end_with?(magnitude)
          [prefix[0...-magnitude.length], suffix]
        elsif magnitude_position == MAGNITUDE_TRAILING && suffix.start_with?(magnitude)
          [prefix, suffix[magnitude.length..-1] || '']
        else
          [prefix, suffix]
        end
      end

      def affix_sign(prefix, suffix)
        minus = data_reader.symbols[:minus_sign] || '-'
        plus = data_reader.symbols[:plus_sign] || '+'
        [prefix.to_s, suffix.to_s].each do |affix|
          return minus if affix.include?(minus)
          return plus if affix.include?(plus)
          return '-' if affix.include?('-')
          return '+' if affix.include?('+')
        end
        ''
      end

      def finite_sign(number, prefix, suffix)
        pattern_sign = affix_sign(prefix, suffix)
        return pattern_sign unless pattern_sign.empty?
        negative?(number) ? (data_reader.symbols[:minus_sign] || '-') : ''
      end

      def negative?(number)
        if number.is_a?(BigDecimal)
          number < 0 || (number.zero? && number.to_s('F').start_with?('-'))
        else
          number < 0 || (number.respond_to?(:zero?) && number.zero? && (1.0 / number) < 0)
        end
      end

      def finite?(number)
        number.respond_to?(:finite?) ? number.finite? : true
      end

      def shared_precision(left, right)
        candidates = [left, right].select { |number| finite?(number) }
        return 0 if candidates.empty?
        candidates.map { |number| precision_from(number) }.max
      end

    end
  end
end
