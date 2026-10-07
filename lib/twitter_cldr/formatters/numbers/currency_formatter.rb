# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    class CurrencyFormatter < NumberFormatter

      def format(tokens, number, options = {})
        prepare_currency_options(options)
        super.gsub('¤', currency_symbol(options))
      end

      def format_parts(tokens, number, options = {})
        prepare_currency_options(options)
        symbol = currency_symbol(options)

        super.tap do |parts|
          parts.prefix = parts.prefix.gsub('¤', symbol)
          parts.suffix = parts.suffix.gsub('¤', symbol)
        end
      end

      def prepare_range_options(left, right, options)
        prepare_currency_options(options)
      end

      private

      def prepare_currency_options(options)
        options[:currency] ||= "USD"
        options[:locale] ||= :en

        digits_and_rounding = resource(options[:currency])
        options[:precision] ||= digits_and_rounding[:digits]
        options[:rounding] ||= digits_and_rounding[:rounding]
      end

      def currency_symbol(options)
        currency = TwitterCldr::Shared::Currencies.for_code(options[:currency], options[:locale])
        currency ||= {
          currency:    options[:currency],
          symbol:      options[:currency],
          cldr_symbol: options[:currency]
        }

        # overwrite with explicit symbol if given
        currency[:symbol] = options[:symbol] if options[:symbol]

        symbol = options[:use_cldr_symbol] ? currency[:cldr_symbol] : currency[:symbol]
        symbol || currency[:currency].to_s
      end

      def resource(code)
        @resource ||= TwitterCldr.get_resource(:shared, :currency_digits_and_rounding)
        @resource[code.to_sym] || @resource[:DEFAULT]
      end

    end
  end
end
