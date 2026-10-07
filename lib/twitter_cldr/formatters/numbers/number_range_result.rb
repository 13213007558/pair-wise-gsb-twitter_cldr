# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters
    # Value object returned by the number range entry points. Besides the
    # final +:text+ it carries the fragments it is made of. Every fragment
    # records its origin:
    #
    #   :left   - taken from the formatted start (left endpoint)
    #   :right  - taken from the formatted end (right endpoint)
    #   :shared - identical for both endpoints (folded affix/unit/magnitude
    #             or range-specific punctuation such as the separator)
    #
    # The fragments, when concatenated, always reproduce +text+ byte for
    # byte, and each fragment's :start/:end offsets slice back into it.
    class NumberRangeResult

      SOURCES = [:left, :right, :shared].freeze

      Fragment = Struct.new(:text, :source, :start, :end, keyword_init: true) do
        def shared?
          source == :shared
        end
      end

      KIND_SINGLE = :single
      KIND_APPROXIMATE = :approximate
      KIND_RANGE = :range

      attr_reader :text, :fragments, :kind, :left_text, :right_text

      def initialize(fragments, kind, left_text: nil, right_text: nil)
        @fragments = freeze_offsets(fragments)
        @kind = kind
        @left_text = left_text
        @right_text = right_text
        @text = @fragments.map(&:text).join
      end

      def range?
        kind == KIND_RANGE
      end

      def approximate?
        kind == KIND_APPROXIMATE
      end

      def single?
        kind == KIND_SINGLE
      end

      def to_s
        text
      end

      # Fragments attributed to a single endpoint (i.e. not :shared).
      def fragments_for(source)
        fragments.select { |fragment| fragment.source == source }
      end

      # Re-slices the fragment offsets out of the final text, asserting the
      # offsets remain accurate.
      def slice(fragment)
        text[fragment.start...fragment.end]
      end

      private

      def freeze_offsets(fragments)
        cursor = 0
        fragments.each_with_object([]) do |fragment, ret|
          text = fragment.text.to_s
          next if text.empty?

          unless SOURCES.include?(fragment.source)
            raise ArgumentError, "unknown fragment source #{fragment.source.inspect}"
          end

          start = cursor
          cursor += text.length
          ret << Fragment.new(
            text: text,
            source: fragment.source,
            start: start,
            end: cursor
          )
        end
      end

    end
  end
end
