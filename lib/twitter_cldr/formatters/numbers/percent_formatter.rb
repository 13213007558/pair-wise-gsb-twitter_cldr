# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    class PercentFormatter < NumberFormatter

      DEFAULT_PERCENT_SIGN = "%"

      def format(tokens, number, options = {})
        super(tokens, number, options).gsub('¤', data_reader.symbols[:percent_sign] || DEFAULT_PERCENT_SIGN)
      end

      def format_parts(tokens, number, options = {})
        percent_sign = data_reader.symbols[:percent_sign] || DEFAULT_PERCENT_SIGN

        super.tap do |parts|
          parts.prefix = parts.prefix.gsub('¤', percent_sign)
          parts.suffix = parts.suffix.gsub('¤', percent_sign)
        end
      end

    end
  end
end
