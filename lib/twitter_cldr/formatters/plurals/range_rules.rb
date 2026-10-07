# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    module Plurals
      module RangeRules

        ROOT_LOCALE = :root

        class << self

          # Returns the plural category of a range whose endpoints have the
          # given plural categories. Falls back to the category of the range
          # end when the locale defines no matching rule, per CLDR.
          def rule_for(start_rule, end_rule, locale = TwitterCldr.locale)
            start_rule = start_rule.to_sym
            end_rule = end_rule.to_sym
            return end_rule if start_rule == end_rule

            rules = rules_for(locale)
            rules.fetch(start_rule, {}).fetch(end_rule, end_rule)
          end

          def rules_for(locale)
            cache_key = TwitterCldr.convert_locale(locale)
            rules_cache[cache_key] ||= begin
              candidate = locale_candidates(cache_key).find do |candidate_locale|
                resource.key?(candidate_locale) || resource.key?(candidate_locale.to_s)
              end
              candidate ? (resource[candidate] || resource[candidate.to_s]) : {}
            end
          end

          def clear_cache
            @rules_cache = {}
            @resource = nil
          end

          private

          def locale_candidates(locale)
            parsed = TwitterCldr::Shared::Locale.parse(locale.to_s.tr('_', '-'))
            (parsed.permutations('-').map(&:to_sym) + [ROOT_LOCALE]).uniq
          end

          def rules_cache
            @rules_cache ||= {}
          end

          def resource
            @resource ||= TwitterCldr.get_resource(:shared, :plural_ranges)
          end

        end

      end
    end
  end
end
