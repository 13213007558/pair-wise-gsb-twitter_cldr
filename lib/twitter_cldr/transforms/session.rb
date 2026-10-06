# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Transforms

    # Raised when the undecided tail of an incremental transform session
    # grows beyond the configured limit. Carries the rule that is preventing
    # the session from finalizing any more output.
    class PendingLimitExceededError < StandardError
      attr_reader :rule, :limit

      def initialize(rule, limit)
        @rule = rule
        @limit = limit

        super(
          "pending text limit of #{limit} characters exceeded; rule " \
          "##{rule.index} (#{rule.original_rule_text.strip}) may still " \
          "match additional input, so no further output can be finalized"
        )
      end
    end

    # Raised when text is pushed into a session that has already been
    # finished.
    class SessionFinishedError < StandardError; end

    # An incremental (streaming) transform session. Text is fed in chunks
    # via #push and the stream is terminated with #finish. Both methods
    # return output that is already determined and will never change, no
    # matter what input follows. The concatenation of everything returned
    # by #push and #finish is exactly the result of transforming the
    # concatenation of all pushed text in one shot.
    #
    # When the tail of the buffered text could still participate in a longer
    # rule match (e.g. a rule whose after-context hasn't arrived yet), the
    # session retains the necessary text instead of emitting output it might
    # have to take back. The retained region is bounded by :max_pending; if
    # it grows beyond the limit, PendingLimitExceededError is raised naming
    # the responsible rule rather than emitting a potentially wrong result.
    # Only #finish treats the end of the buffer as the true end of the text.
    #
    # Sessions built from the same rule set share the (read-only) rules but
    # keep their own cursor and pending text, so they are fully independent.
    #
    #   rule_set = TwitterCldr::Transforms::Transformer.get('Latin-Greek')
    #   session = rule_set.session
    #   session.push('hello ')
    #   session.push('world')
    #   session.finish
    class Session
      DEFAULT_MAX_PENDING = 1024

      attr_reader :rule_set, :max_pending

      def initialize(rule_set, max_pending: DEFAULT_MAX_PENDING)
        @rule_set = rule_set
        @max_pending = max_pending
        @stages = rule_set.rules.map { |rule| build_stage(rule) }
        @stages << PassthroughStage.new if @stages.empty?
        @finished = false
      end

      # Feeds a chunk of text into the session and returns output that is
      # guaranteed to be final.
      def push(text)
        if finished?
          raise SessionFinishedError,
            'cannot push text into a finished session'
        end

        @stages.first.feed(text.to_s)
        pump(final: false)
      end

      # Terminates the stream, treats the end of the buffered text as the
      # true end of the input, and returns the remaining output.
      def finish
        return +'' if finished?
        @finished = true
        pump(final: true)
      end

      def finished?
        @finished
      end

      private

      def pump(final:)
        output = +''

        @stages.each_with_index do |stage, idx|
          committed = stage.process(final: final)

          if idx < @stages.size - 1
            @stages[idx + 1].feed(committed)
          else
            output << committed
          end
        end

        output
      end

      def build_stage(rule)
        if rule.is_conversion_rule_set?
          ConversionStage.new(rule, @max_pending)
        elsif rule.respond_to?(:null?) && rule.null?
          PassthroughStage.new
        elsif rule.is_a?(Transforms::NormalizationTransform) &&
              rule.forward_transform
          NormalizationStage.new(rule)
        elsif rule.is_a?(Transforms::CasingTransform) &&
              %w(lower upper).include?(rule.forward_transform)
          CasingStage.new(rule)
        elsif rule.respond_to?(:apply_to)
          # Whole-text rules (casing, normalization, named transforms, ...)
          # can't be applied incrementally in general, so they're applied
          # once the input is complete.
          BarrierStage.new(rule)
        else
          raise ArgumentError,
            "cannot apply #{rule.class} incrementally"
        end
      end

      # Applies a ConversionRuleSet incrementally. Already-committed text is
      # kept (read-only) so before-contexts can still be matched against it;
      # the cursor never moves backwards, so committed text is never touched
      # again.
      class ConversionStage
        def initialize(rule_set, max_pending)
          @rule_set = rule_set
          @max_pending = max_pending
          @text = +''
          @cursor = Cursor.new(@text)
          @emitted = 0
          @partials = {}
        end

        def feed(text)
          @text << text
        end

        def process(final:)
          until @cursor.eos?
            if @rule_set.filter_rule.matches?(@cursor)
              if !final && (rule = pending_rule)
                pending = @text.size - @cursor.position

                if pending > @max_pending
                  raise PendingLimitExceededError.new(rule, @max_pending)
                end

                break
              end

              if (rule_match = @rule_set.find_matching_rule_at(@cursor))
                start = rule_match.start
                stop = rule_match.stop
                replacement = rule_match.replacement
                @cursor.text[start...stop] = replacement

                @cursor.advance(
                  replacement.size + rule_match.cursor_offset
                )
              else
                @cursor.advance
              end
            else
              @cursor.advance
            end
          end

          commit
        end

        private

        def commit
          stop = [@cursor.position, @text.size].min
          committed = @text[@emitted...stop] || +''
          @emitted = stop
          committed
        end

        # Returns the first candidate rule whose match outcome at the
        # cursor's current position could still change if more input
        # arrived, or nil if every candidate's behavior is already final.
        def pending_rule
          position = @cursor.position

          @rule_set.candidate_rules_at(@cursor).each do |rule|
            return rule if rule_pending?(rule)
          end

          nil
        end

        def rule_pending?(rule)
          side = rule.left
          before_partial, key_partial, after_partial = partials_for(rule)

          # A before-context match straddling the cursor may start anywhere
          # before it; if any such start could still extend its match, the
          # outcome here isn't final.
          if before_partial
            (0..@cursor.position).each do |start|
              return true if before_partial.partial?(@text, start)
            end
          end

          before_match = side.match_before(@cursor)
          return false unless before_match

          key_start = before_match.end(0)

          # The key would start at or past the end of the buffer, so
          # whether (and how) the rule matches depends on future input.
          return true if key_start >= @text.size

          return true if key_partial.partial?(@text, key_start)

          key_match = side.match_key(@cursor, before_match)
          return false unless key_match

          after_partial.partial?(@text, key_match.end(0))
        end

        def partials_for(rule)
          @partials[rule] ||= begin
            side = rule.left

            [
              side.before_context.empty? ? nil : compile_partial(side.before_context_uregexp),
              compile_partial(side.key_uregexp),
              compile_partial(side.after_context_uregexp)
            ]
          end
        end

        def compile_partial(uregexp)
          PartialRegexp.compile(uregexp.elements)
        rescue PartialRegexp::UnsupportedPatternError
          PartialRegexp.always_partial
        end
      end

      # Buffers whole-text rules (normalization, casing, named transforms)
      # and applies them once the input is complete.
      class BarrierStage
        def initialize(rule)
          @rule = rule
          @buffer = +''
          @processed = false
        end

        def feed(text)
          @buffer << text
        end

        def process(final:)
          return +'' unless final
          return +'' if @processed
          @processed = true

          cursor = Cursor.new(@buffer)
          @rule.apply_to(cursor)
          cursor.text
        end
      end

      # Incremental normalization. Canonical reordering and composition can
      # only happen inside a "segment" (a starter followed by combining
      # marks, or a Hangul jamo/syllable run), so everything before the
      # buffer's final, potentially incomplete segment can be normalized and
      # committed right away.
      class NormalizationStage
        HANGUL_RANGES = [
          0x1100..0x1112,  # Hangul L (choseong)
          0x1161..0x1175,  # Hangul V (jungseong)
          0x11A8..0x11C2,  # Hangul T (jongseong)
          0xAC00..0xD7A3   # Hangul syllables
        ].freeze

        class << self
          def properties_database
            @properties_database ||= TwitterCldr::Shared::PropertiesDatabase.new
          end
        end

        def initialize(rule)
          @form = rule.forward_transform
          @buffer = +''
        end

        def feed(text)
          @buffer << text
        end

        def process(final:)
          if final
            normalize(@buffer).tap { @buffer = +'' }
          else
            keep = commit_length
            return +'' if keep == 0

            normalize(@buffer[0...keep]).tap do
              @buffer = @buffer[keep..-1] || +''
            end
          end
        end

        private

        def commit_length
          size = @buffer.size

          if composing?
            # hold back the trailing combining run, the starter it belongs
            # to, and any Hangul run that could still compose further
            i = size
            i -= 1 while i > 0 && combining?(@buffer[i - 1])
            i -= 1 if i > 0
            i -= 1 while i > 0 && hangul?(@buffer[i - 1])
            i
          else
            # decomposing forms only reorder combining marks, so just hold
            # back the trailing combining run
            i = size
            i -= 1 while i > 0 && combining?(@buffer[i - 1])
            i
          end
        end

        def composing?
          @form == :nfc || @form == :nfkc
        end

        def combining?(char)
          ccc(char.ord) != '0'
        end

        def hangul?(char)
          codepoint = char.ord
          HANGUL_RANGES.any? { |range| range.cover?(codepoint) }
        end

        def ccc(codepoint)
          @ccc_cache ||= {}
          @ccc_cache[codepoint] ||=
            self.class.properties_database
              .properties_for_code_point(codepoint)
              .canonical_combining_class.first
        end

        def normalize(text)
          TwitterCldr::Normalization.normalize(text, using: @form)
        end
      end

      # Lower/upper casing is a per-character mapping in this
      # implementation, so it can be applied to pushed text immediately.
      # (Title casing is word-boundary dependent and stays a BarrierStage.)
      class CasingStage
        def initialize(rule)
          @form = rule.forward_transform
          @buffer = +''
        end

        def feed(text)
          @buffer << text
        end

        def process(final:)
          committed =
            case @form
            when 'lower'
              TwitterCldr::Shared::Caser.downcase(@buffer)
            when 'upper'
              TwitterCldr::Shared::Caser.upcase(@buffer)
            else
              @buffer
            end

          @buffer = +''
          committed
        end
      end

      # Forwards input immediately (used for no-op rules).
      class PassthroughStage
        def initialize
          @buffer = +''
        end

        def feed(text)
          @buffer << text
        end

        def process(final:)
          committed = @buffer
          @buffer = +''
          committed
        end
      end
    end

  end
end
