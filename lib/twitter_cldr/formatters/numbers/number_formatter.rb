# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    class NumberFormatter < Formatter

      # Decomposed representation of a formatted number. Used by range
      # formatting, which needs to know which parts of the text are
      # affixes (prefix/suffix) and which part is the number itself.
      Parts = Struct.new(:prefix, :number, :suffix) do
        def text
          "#{prefix}#{number}#{suffix}"
        end
      end

      attr_reader :data_reader

      def initialize(data_reader)
        @data_reader = data_reader
      end

      def format(tokens, number, options = {})
        options[:precision] ||= precision_from(number)
        options[:type] ||= :decimal

        prefix, suffix, integer_format, fraction_format = *partition_tokens(tokens)
        number = truncate_number(number, integer_format.format.length)

        int, fraction = parse_number(number, options)
        result =  integer_format.apply(int, options)
        result << fraction_format.apply(fraction, options) if fraction

        number_system.transliterate(
          "#{prefix.to_s}#{result}#{suffix.to_s}"
        )
      end

      # Formats a single number and returns a Parts struct instead of a
      # plain string. Shares precision/rounding options with the caller via
      # the (mutated) options hash, just like #format does.
      def format_parts(tokens, number, options = {})
        options[:precision] ||= precision_from(number)
        options[:type] ||= :decimal

        prefix, suffix, integer_format, fraction_format = *partition_tokens(tokens)

        result = if special_number?(number)
          special_text_for(number)
        else
          number = truncate_number(number, integer_format.format.length)
          int, fraction = parse_number(number, options)
          text = integer_format.apply(int, options)
          text << fraction_format.apply(fraction, options) if fraction
          text
        end

        Parts.new(
          number_system.transliterate(prefix.to_s),
          number_system.transliterate(result),
          number_system.transliterate(suffix.to_s)
        )
      end

      # Unifies precision/rounding options for both ends of a range before
      # either end is formatted. Subclasses (e.g. currency) override this to
      # supply their own defaults.
      def prepare_range_options(left, right, options)
        return if options[:precision]

        precisions = [left, right].reject do |number|
          special_number?(number)
        end.map { |number| precision_from(number) }

        options[:precision] = precisions.max || 0
      end

      def special_number?(number)
        (number.respond_to?(:infinite?) && number.infinite?) ||
          (number.respond_to?(:nan?) && number.nan?)
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

      def special_text_for(number)
        if number.respond_to?(:nan?) && number.nan?
          data_reader.symbols[:nan] || 'NaN'
        else
          data_reader.symbols[:infinity] || '∞'
        end
      end

      def number_system
        @number_system ||= TwitterCldr::Shared::NumberingSystem.for_name(
          data_reader.number_system
        )
      end

      def partition_tokens(tokens)
        [
          token_val_from(tokens[0]),
          token_val_from(tokens[2]),
          Numbers::Integer.new(
            tokens[1],
            data_reader.symbols
          ),
          Numbers::Fraction.new(
            tokens[1],
            data_reader.symbols
          )
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
        return 0 if num.is_a?(BigDecimal) && num.fix == num
        parts = (num.is_a?(BigDecimal) ? num.to_s("F") : num.to_s ).split(".")
        parts.size == 2 ? parts[1].size : 0
      end

      def abbreviate?(number)
        TwitterCldr::DataReaders::NumberDataReader.within_abbreviation_range?(number) && (
          data_reader.format == :short ||
          data_reader.format == :long
        )
      end

    end
  end
end
