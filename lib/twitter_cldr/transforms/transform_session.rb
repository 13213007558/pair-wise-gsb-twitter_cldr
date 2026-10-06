# encoding: UTF-8

module TwitterCldr
  module Transforms
    class TransformSessionError < StandardError
      attr_reader :rule, :rule_set

      def initialize(message = nil, rule: nil, rule_set: nil)
        @rule = rule
        @rule_set = rule_set
        super(message)
      end
    end

    class RetentionLimitExceededError < TransformSessionError; end
    class TransformSessionFinishedError < TransformSessionError; end

    class TransformSession
      DEFAULT_MAX_PENDING_SIZE = 4096

      attr_reader :rule_set, :max_pending_size, :pending_size

      def self.new(rule_set, max_pending_size = DEFAULT_MAX_PENDING_SIZE)
        rule_set.is_a?(ConversionRuleSet) ?
          rule_set.incremental_session(max_pending_size) :
          super
      end

      def initialize(rule_set, max_pending_size = DEFAULT_MAX_PENDING_SIZE)
        @rule_set = rule_set
        @max_pending_size = max_pending_size
        @conversion_sessions = {}
        @buffer = ''
        @finished = false
        @pending_size = 0
      end

      def push(text)
        ensure_not_finished!
        chunk = text.to_s
        return '' if chunk.empty?

        if global_barrier_index
          buffer(chunk)
        else
          result = apply_pre_global_rules(chunk, false)
          buffer(result)
          update_pending_size
          result
        end
      end

      def finish
        ensure_not_finished!
        @finished = true

        remaining = apply_pre_global_rules('', true)
        @buffer << remaining
        update_pending_size

        result = if global_barrier_index
          tail_rule_set.transform(@buffer)
        else
          @buffer
        end

        @buffer = ''
        @pending_size = 0
        result
      end

      def finished?
        @finished
      end

      private

      def apply_pre_global_rules(chunk, finishing)
        result = chunk

        pre_global_conversion_sets.each do |conversion_rule_set|
          session = conversion_session(conversion_rule_set)
          result = finishing ? session.finish : session.push(result)
        end

        result
      end

      def pre_global_conversion_sets
        @pre_global_conversion_sets ||= begin
          barrier = global_barrier_index || rule_set.rules.size
          rule_set.rules[0...barrier].select(&:is_conversion_rule_set?)
        end
      end

      def global_barrier_index
        @global_barrier_index ||= rule_set.rules.index do |rule|
          rule.is_transform_rule? && !identity_transform?(rule)
        end
      end

      def identity_transform?(rule)
        rule.is_a?(Transforms::NullTransform) ||
          rule.is_a?(Transforms::BlankTransform)
      end

      def conversion_session(conversion_rule_set)
        @conversion_sessions[conversion_rule_set.object_id] ||=
          ConversionSession.new(conversion_rule_set, max_pending_size)
      end

      def tail_rule_set
        RuleSet.new(
          rule_set.rules[global_barrier_index..-1].dup,
          rule_set.transform_id
        )
      end

      def buffer(text)
        @buffer << text

        if @buffer.size > max_pending_size
          rule = rule_set.rules[global_barrier_index]
          raise RetentionLimitExceededError.new(
            "cannot continue because #{rule_description(rule)} requires end-of-input context and the retained text exceeds #{max_pending_size} characters",
            rule: rule,
            rule_set: rule_set
          )
        end

        update_pending_size
        text
      end

      def update_pending_size
        pending = @buffer.size

        pre_global_conversion_sets.each do |conversion_rule_set|
          pending += conversion_session(conversion_rule_set).pending_size
        end

        @pending_size = pending
      end

      def ensure_not_finished!
        if @finished
          raise TransformSessionFinishedError,
            'cannot push to or finish a finished transform session'
        end
      end

      def rule_description(rule)
        rule.respond_to?(:original_rule_text) && rule.original_rule_text ?
          "rule #{rule.original_rule_text.inspect}" :
          "rule #{rule.class.name.split('::').last}"
      end
    end

    class ConversionSession
      DEFAULT_MAX_PENDING_SIZE = 4096

      attr_reader :rule_set, :max_pending_size, :pending_size

      def initialize(rule_set, max_pending_size = DEFAULT_MAX_PENDING_SIZE)
        @rule_set = rule_set
        @max_pending_size = max_pending_size
        @context = ''
        @pending = ''
        @finished = false
        @pending_size = 0
      end

      def push(text)
        ensure_not_finished!
        @pending << text.to_s
        process
      end

      def finish
        ensure_not_finished!
        @finished = true
        process
      end

      def finished?
        @finished
      end

      private

      def process
        output = ''

        loop do
          text = @context + @pending
          cursor = Cursor.new(text)
          cursor.advance(@context.size)
          break if cursor.eos?

          if cursor.eos?
            break
          end

          unless rule_set.filter_rule.matches?(cursor)
            output << advance_to(text, cursor.position + 1)
            next
          end

          rule_match = rule_set.matching_rule_at(cursor)

          if rule_match
            blocker = if rule_match.stop >= text.size &&
                         rule_match.rule.left.key_match_extendable?(
                           text, rule_match.stop
                         )
              rule_match.rule
            else
              possible_rule(cursor, before_index: rule_match.rule.index)
            end

            if blocker
              ensure_capacity(blocker)
              break
            end

            replacement = rule_match.replacement
            text[rule_match.start...rule_match.stop] = replacement
            new_position = replacement.size + rule_match.cursor_offset
            output << advance_to(text, new_position)
          else
            if @finished
              output << advance_to(text, cursor.position + 1)
            else
              blocker = possible_rule(cursor)

              if blocker
                ensure_capacity(blocker)
                break
              end

              output << advance_to(text, cursor.position + 1)
            end
          end
        end

        @pending_size = @pending.size
        output
      end

      def possible_rule(cursor, before_index: nil)
        candidates = rule_set.candidate_rules(cursor).sort_by(&:index)

        candidates.find do |rule|
          next false if before_index && rule.index >= before_index
          next false unless rule.forward?
          next false unless rule.left.key_prefix_match?(cursor)

          if rule.left.before_context_match?(cursor)
            true
          elsif incomplete_context?
            rule.left.unbounded_before_context?
          else
            false
          end
        end
      end

      def advance_to(text, position)
        position = [[position, @context.size].max, text.size].min
        output = text[@context.size...position].to_s
        boundary = [0, position - context_limit].max
        @context = text[boundary...position].to_s
        @pending = text[position..-1].to_s
        output
      end

      def context_limit
        @context_limit ||= [
          max_pending_size,
          rule_set.before_context_limit
        ].max
      end

      def incomplete_context?
        rule_set.unbounded_before_context_rules.any? &&
          @context.size < context_limit
      end

      def ensure_capacity(rule)
        return unless @pending.size > max_pending_size

        raise RetentionLimitExceededError.new(
          "cannot continue because #{rule_description(rule)} may match a longer sequence and the retained text exceeds #{max_pending_size} characters",
          rule: rule,
          rule_set: rule_set
        )
      end

      def ensure_not_finished!
        if @finished
          raise TransformSessionFinishedError,
            'cannot push to or finish a finished conversion session'
        end
      end

      def rule_description(rule)
        if rule.respond_to?(:original_rule_text) && rule.original_rule_text
          "rule #{rule.original_rule_text.inspect}"
        else
          "rule ##{rule.index}"
        end
      end
    end
  end
end
