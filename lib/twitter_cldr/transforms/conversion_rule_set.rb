# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

# http://unicode.org/reports/tr35/tr35-general.html#Transforms
# http://unicode.org/cldr/utility/transform.jsp

module TwitterCldr
  module Transforms

    class ConversionRuleSet
      attr_reader :filter_rule, :inverse_filter_rule
      attr_reader :rules, :rule_index

      def initialize(filter_rule, inverse_filter_rule, rules)
        @rules = rules
        @filter_rule = filter_rule
        @inverse_filter_rule = inverse_filter_rule
        @rule_index = build_rule_index(rules)
      end

      def forward?
        true
      end

      def backward?
        false
      end

      def is_filter_rule?
        false
      end

      def is_transform_rule?
        false
      end

      def is_conversion_rule?
        false
      end

      def is_conversion_rule_set?
        true
      end

      def invert
        ConversionRuleSet.new(
          inverse_filter_rule, filter_rule, inverted_rules
        )
      end

      def apply_to(cursor)
        until cursor.eos?
          if filter_rule.matches?(cursor)
            rule_match = find_matching_rule_at(cursor)

            if rule_match
              start = rule_match.start
              stop = rule_match.stop
              replacement = rule_match.replacement
              puts "#{cursor.text[start...stop]} -> #{replacement}" if $debug
              cursor.text[start...stop] = replacement

              cursor.advance(
                replacement.size + rule_match.cursor_offset
              )
            else
              cursor.advance
            end
          else
            cursor.advance
          end
        end
      end

      def incremental_session(max_pending_size = nil)
        ConversionSession.new(self, max_pending_size)
      end

      def matching_rule_at(cursor)
        find_matching_rule_at(cursor)
      end

      def candidate_rules(cursor)
        indexed_rules = rule_index.get(cursor.index_values) || []
        blank_rules = rule_index.get([0]) || []
        (indexed_rules + blank_rules).uniq
      end

      def before_context_limit
        @before_context_limit ||= rules.inject(0) do |limit, rule|
          next(limit) unless rule.forward?
          rule_limit = rule.left.before_context_max_size
          [limit, rule_limit].max
        end
      end

      def unbounded_before_context_rules
        @unbounded_before_context_rules ||= rules.select do |rule|
          rule.forward? && rule.left.unbounded_before_context?
        end
      end

      private

      def inverted_rules
        @inverted_rules ||= begin
          rules.each_with_object([]) do |rule, ret|
            if rule.can_invert?
              ret << rule.invert
            end
          end
        end
      end

      def find_matching_rule_at(cursor)
        indexed_match = find_matching_indexed_rule_at(cursor)
        blank_key_match = find_matching_blank_key_rule_at(cursor)

        if indexed_match
          if blank_key_match
            if blank_key_match < indexed_match
              blank_key_match
            else
              indexed_match
            end
          else
            indexed_match
          end
        else
          blank_key_match
        end
      end

      def find_matching_indexed_rule_at(cursor)
        if rules = rule_index.get(cursor.index_values)
          rules.each do |rule|
            if side_match = rule.match(cursor)
              return RuleMatch.new(rule, side_match)
            end
          end
        end

        nil
      end

      def find_matching_blank_key_rule_at(cursor)
        if rules = rule_index.get([0])
          rules.each do |rule|
            if side_match = rule.match(cursor)
              return RuleMatch.new(rule, side_match)
            end
          end
        end

        nil
      end

      def build_rule_index(rules)
        TwitterCldr::Utils::Trie.new.tap do |trie|
          rules.each_with_index do |rule, idx|
            next unless rule.forward?

            if rule.has_codepoints?
              codepoints = rule.codepoints

              if codepoints.size > 0
                rule.codepoints.each do |codepoint|
                  bytes = codepoint.chr('UTF-8').bytes

                  if entry = trie.get(bytes)
                    entry << rule
                  else
                    trie.add(bytes, [rule])
                  end
                end
              end
            else
              if entry = trie.get([0])
                entry << rule
              else
                trie.add([0], [rule])
              end
            end
          end
        end
      end
    end

  end
end
