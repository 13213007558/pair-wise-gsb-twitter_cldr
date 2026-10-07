# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    # Formats a pair of numeric endpoints as a range using CLDR number range
    # patterns and plural range rules.
    #
    # Both endpoints are first formatted with the *same* precision and
    # rounding configuration. Depending on the relationship of the
    # endpoints the result is either:
    #
    #   * a single, exact value when the endpoints are numerically equal
    #     (positive and negative zero are numerically equal);
    #   * a single, approximate value when the endpoints differ numerically
    #     but render identically after rounding;
    #   * a range otherwise.
    #
    # Prefixes, suffixes and compact magnitude markers are folded into a
    # single :shared fragment only when semantically identical for both
    # endpoints. Literal text of the range pattern is always :shared.
    class NumberRangeFormatter < Formatter

      LEFT_PLACEHOLDER = '{0}'.freeze
      RIGHT_PLACEHOLDER = '{1}'.freeze
      PLACEHOLDER_REGEX = /({[01]})/.freeze

      def format(left, right, options = {})
        left = coerce(left)
        right = coerce(right)

        options = apply_type_defaults(options)
        options = data_reader.shared_number_options(left, right, options)
        options[:locale] ||= data_reader.locale

        left_parts = endpoint_parts(left, options)
        right_parts = endpoint_parts(right, options)

        if numerically_equal?(left, right)
          single_result(left_parts)
        elsif left_parts[:full] == right_parts[:full]
          approximate_result(left_parts)
        else
          range_result(left_parts, right_parts)
        end
      end

      private

      def coerce(number)
        return number if number.is_a?(BigDecimal) || number.is_a?(Float)
        Integer(number)
      rescue ArgumentError, TypeError
        BigDecimal(number.to_s)
      end

      # Mirrors the default precision/rounding that CurrencyFormatter would
      # apply to a single value, so both endpoints share a currency-appropriate
      # configuration. Explicit options still take precedence.
      def apply_type_defaults(options)
        return options unless data_reader.type == :currency

        options = options.dup
        code = (options[:currency] || 'USD').to_sym
        resource = TwitterCldr.get_resource(:shared, :currency_digits_and_rounding)
        digits_and_rounding = resource[code] || resource[:DEFAULT]
        options[:precision] ||= digits_and_rounding[:digits]
        options[:rounding] ||= digits_and_rounding[:rounding]
        options
      end

      def endpoint_parts(number, options)
        tokens = data_reader.tokens_for(number, options)
        parts = data_reader.formatter.format_parts(tokens, number, options)
        substitute_symbols(parts, options)
      end

      # Currency and percent formatters leave a placeholder ('¤') or a
      # percent token in the affixes. Apply the same substitution the
      # single-value formatters use so range fragments match their
      # single-value output exactly.
      def substitute_symbols(parts, options)
        symbol = affix_symbol(options)
        return parts unless symbol

        parts[:prefix] = parts[:prefix].to_s.gsub('¤', symbol)
        parts[:suffix] = parts[:suffix].to_s.gsub('¤', symbol)
        recompute_full(parts)
        parts
      end

      def recompute_full(parts)
        parts[:full] = "#{parts[:prefix]}#{parts[:base]}#{parts[:suffix]}"
      end

      def affix_symbol(options)
        case data_reader.type
          when :currency
            currency_symbol(options)
          when :percent
            data_reader.symbols[:percent_sign] || PercentFormatter::DEFAULT_PERCENT_SIGN
        end
      end

      def currency_symbol(options)
        code = options[:currency] || 'USD'
        locale = options[:locale] || data_reader.locale
        currency = TwitterCldr::Shared::Currencies.for_code(code, locale)
        currency ||= { cldr_symbol: code, symbol: code }
        symbol = if options[:symbol]
          options[:symbol]
        elsif options[:use_cldr_symbol]
          currency[:cldr_symbol]
        else
          currency[:symbol]
        end
        symbol || code
      end

      def numerically_equal?(left, right)
        BigDecimal(left.to_s) == BigDecimal(right.to_s)
      rescue ArgumentError, TypeError
        left == right
      end

      def single_result(parts)
        result(fragment_parts(parts, :shared), NumberRangeResult::KIND_SINGLE, parts, parts)
      end

      def approximate_result(parts)
        sign = approximately_sign
        fragments = [fragment(sign, :shared)]
        fragments.concat(fragment_parts(parts, :shared))
        result(fragments, NumberRangeResult::KIND_APPROXIMATE, parts, parts)
      end

      def range_result(left_parts, right_parts)
        left_rule = plural_rule_for(left_parts)
        right_rule = plural_rule_for(right_parts)
        pattern = data_reader.range_pattern(left_rule, right_rule)

        fragments = compose_range(pattern, left_parts, right_parts)
        result(fragments, NumberRangeResult::KIND_RANGE, left_parts, right_parts)
      end

      # Builds the attributed fragment list for an actual range.
      #
      # Prefixes and suffixes are folded (emitted once, as :shared) only
      # when they appear *outside* the {0}/{1} placeholders in the range
      # pattern and are identical for both endpoints; this prevents, for
      # example, the minus/currency prefix of a negative right endpoint from
      # disappearing. Compact magnitude markers shared by both endpoints
      # are folded once at the appropriate (leading/trailing) edge of the
      # numeric bodies. Everything else stays attributed to :left or
      # :right.
      def compose_range(pattern, left_parts, right_parts)
        fragments = []
        segments = pattern_segments(pattern)
        left_index = segments.index(LEFT_PLACEHOLDER)
        right_index = segments.index(RIGHT_PLACEHOLDER)

        prefix_pattern = left_index ? segments[0...left_index].join : ''
        suffix_pattern = right_index ? segments[(right_index + 1)..-1].join : ''

        # Affixes/magnitudes are only folded when the range pattern itself
        # contributes no surrounding text (e.g. "from {0} to {1}" keeps each
        # endpoint self-contained).
        hoist = prefix_pattern.empty? && suffix_pattern.empty?

        folded_prefix = hoist ? hoistable_prefix(left_parts, right_parts) : ''
        folded_suffix = hoist ? hoistable_suffix(left_parts, right_parts) : ''
        folded_leading = hoist ? shared_magnitude(left_parts, right_parts, :leading) : ''
        folded_trailing = hoist ? shared_magnitude(left_parts, right_parts, :trailing) : ''

        append(fragments, folded_prefix, :shared)
        append(fragments, folded_leading, :shared)

        segments.each do |segment|
          case segment
            when LEFT_PLACEHOLDER
              emit_endpoint(
                fragments, left_parts, right_parts, :left,
                folded_prefix, folded_suffix,
                folded_leading, folded_trailing
              )
            when RIGHT_PLACEHOLDER
              emit_endpoint(
                fragments, right_parts, left_parts, :right,
                folded_prefix, folded_suffix,
                folded_leading, folded_trailing
              )
            else
              append(fragments, segment, :shared)
          end
        end

        append(fragments, folded_trailing, :shared)
        append(fragments, folded_suffix, :shared)
        fragments
      end

      def emit_endpoint(fragments, parts, other_parts, source,
                        folded_prefix, folded_suffix,
                        folded_leading, folded_trailing)
        prefix_text = parts[:prefix].to_s
        unless folded_prefix.include?(prefix_text) || prefix_text.empty?
          append_affix(fragments, prefix_text, other_parts[:prefix].to_s, source)
        end
        if folded_leading.empty?
          append_magnitude(fragments, parts, other_parts, :leading, source)
        end
        append(fragments, parts[:integer], source)
        append(fragments, parts[:fraction], source)
        if folded_trailing.empty?
          append_magnitude(fragments, parts, other_parts, :trailing, source)
        end
        suffix_text = parts[:suffix].to_s
        unless folded_suffix.include?(suffix_text) || suffix_text.empty?
          append_affix(fragments, suffix_text, other_parts[:suffix].to_s, source)
        end
      end

      # Emits an endpoint affix. When the affix is identical on both
      # endpoints and carries no sign, it is marked :shared (both endpoints
      # contributed it), although it is still rendered with this endpoint
      # because it was not hoisted. Sign-bearing affixes always remain
      # endpoint-specific so minus/plus is never implicitly merged.
      def append_affix(fragments, text, other_text, source)
        if text == other_text && !sign_affix?(text)
          append(fragments, text, :shared)
        else
          append(fragments, text, source)
        end
      end

      def append_magnitude(fragments, parts, other_parts, position, source)
        marker = parts[:magnitude]
        return if marker.nil? || marker.empty?
        return unless parts[:magnitude_position] == position
        same = marker == other_parts[:magnitude] &&
          other_parts[:magnitude_position] == position
        append(fragments, marker, same ? :shared : source)
      end

      # A prefix can only be hoisted (rendered once, outside the
      # placeholders) when both endpoints carry the exact same, sign-free
      # prefix. Anything sign-bearing stays with each endpoint.
      def hoistable_prefix(left_parts, right_parts)
        prefix = left_parts[:prefix].to_s
        return '' if prefix.empty?
        return '' unless prefix == right_parts[:prefix].to_s
        sign_affix?(prefix) ? '' : prefix
      end

      def hoistable_suffix(left_parts, right_parts)
        suffix = left_parts[:suffix].to_s
        return '' if suffix.empty?
        return '' unless suffix == right_parts[:suffix].to_s
        sign_affix?(suffix) ? '' : suffix
      end

      SIGN_AFFIX_REGEX = /[\-+\u{2212}]/.freeze

      def sign_affix?(text)
        SIGN_AFFIX_REGEX.match?(text.to_s)
      end

      def shared_magnitude(left_parts, right_parts, position)
        marker = left_parts[:magnitude]
        return '' if marker.nil? || marker.empty?
        return '' unless left_parts[:magnitude_position] == position
        marker == right_parts[:magnitude] &&
          right_parts[:magnitude_position] == position ? marker : ''
      end

      # Magnitude rendered inside an endpoint placeholder. A magnitude shared
      # by both endpoints is omitted here and emitted once as :shared.
      def endpoint_magnitude(parts, other_parts, position)
        marker = parts[:magnitude]
        return '' if marker.nil? || marker.empty?
        return '' unless parts[:magnitude_position] == position
        shared = marker == other_parts[:magnitude] &&
          other_parts[:magnitude_position] == position
        shared ? '' : marker
      end

      def pattern_segments(pattern)
        pattern.to_s.split(PLACEHOLDER_REGEX).reject(&:empty?)
      end

      # Plural categories used to select plural range patterns are evaluated
      # against the displayed (rounded, possibly compacted) magnitude of
      # each endpoint, matching CLDR's interval rules. Non-finite values
      # fall back to :other.
      def plural_rule_for(parts)
        value = BigDecimal(parts[:number].to_s)
        data_reader.plural_rule(value)
      rescue ArgumentError, TypeError
        :other
      end

      def fragment_parts(parts, source)
        [
          fragment(parts[:prefix], source),
          fragment(leading_or_trailing_magnitude(parts, :leading), source),
          fragment(parts[:integer], source),
          fragment(parts[:fraction], source),
          fragment(leading_or_trailing_magnitude(parts, :trailing), source),
          fragment(parts[:suffix], source)
        ].compact
      end

      def leading_or_trailing_magnitude(parts, position)
        parts[:magnitude_position] == position ? parts[:magnitude] : ''
      end

      def fragment(text, source)
        return nil if text.nil? || text.empty?
        NumberRangeResult::Fragment.new(text: text, source: source)
      end

      def append(fragments, text, source)
        built = fragment(text, source)
        fragments << built if built
      end

      def result(fragments, kind, left_parts, right_parts)
        NumberRangeResult.new(
          fragments, kind,
          left_text: left_parts[:full],
          right_text: right_parts[:full]
        )
      end

      def approximately_sign
        data_reader.symbols[:approximately_sign] || '~'
      end

    end
  end
end
