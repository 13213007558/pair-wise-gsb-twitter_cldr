# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Shared
    module NumberRanges

      TYPES = [:decimal, :percent, :currency].freeze

      DEFAULT_PATTERN = "{0}–{1}"

      class << self

        # Returns the range pattern for the given locale, number type and the
        # plural categories of both endpoints, following CLDR's plural range
        # rules with a deterministic locale/parent fallback.
        def pattern_for(locale, type, left_rule, right_rule)
          each_locale(locale) do |loc|
            table = resource[loc]
            next unless table

            pattern = plural_pattern(table, left_rule, right_rule) ||
              fallback_pattern(table, type)
            return pattern if pattern
          end

          DEFAULT_PATTERN
        end

        # Returns the locale-tailored fallback range pattern for a number
        # type (CLDR's miscPattern entry), walking the locale ancestry.
        def fallback_for(locale, type)
          each_locale(locale) do |loc|
            table = resource[loc]
            pattern = fallback_pattern(table, type) if table
            return pattern if pattern
          end

          DEFAULT_PATTERN
        end

        private

        def plural_pattern(table, left_rule, right_rule)
          ranges = table[:plural_ranges]
          return unless ranges.is_a?(Hash)

          left = ranges[left_rule] || ranges[:other]
          return unless left.is_a?(Hash)

          left[right_rule] || left[:other]
        end

        def fallback_pattern(table, type)
          patterns = table[:patterns]
          return unless patterns.is_a?(Hash)

          patterns[type.to_sym]
        end

        def each_locale(locale)
          locale = TwitterCldr.convert_locale(locale).to_sym

          chain = begin
            Shared::Locale.parse(locale).ancestor_chain.map do |ancestor|
              ancestor.to_s.to_sym
            end
          rescue StandardError
            [locale]
          end

          chain << :root unless chain.include?(:root)
          chain << DEFAULT_LOCALE_KEY unless chain.include?(DEFAULT_LOCALE_KEY)

          chain.each { |key| yield(key) }
          nil
        end

        def resource
          @resource ||= TwitterCldr.get_resource(:shared, :number_ranges)
        end

      end

      DEFAULT_LOCALE_KEY = :en
      private_constant :DEFAULT_LOCALE_KEY

    end
  end
end
