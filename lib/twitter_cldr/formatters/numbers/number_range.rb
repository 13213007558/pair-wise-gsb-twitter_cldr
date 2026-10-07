# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Formatters

    # The result of formatting a range of numbers. Contains the final text
    # along with a list of spans that map each segment of the text back to
    # its source: the left end of the range (:left), the right end
    # (:right), or both ends / the range pattern itself (:shared).
    class NumberRange

      KINDS = [:single, :approximate, :range].freeze

      Span = Struct.new(:start, :length, :source) do
        def end
          start + length
        end

        def slice(text)
          text[start, length]
        end
      end

      attr_reader :text, :spans, :kind

      # segments is an array of [text, source] pairs in display order.
      def initialize(text, segments, kind)
        @text = text
        @kind = kind
        @spans = build_spans(segments)
      end

      def to_s
        text
      end

      def ==(other)
        other.is_a?(NumberRange) &&
          text == other.text &&
          spans == other.spans &&
          kind == other.kind
      end

      # Yields [source, substring] pairs sliced from the final text.
      def segments
        spans.map { |span| [span.source, span.slice(text)] }
      end

      private

      def build_spans(segments)
        spans = []
        offset = 0

        segments.each do |segment_text, source|
          next if segment_text.nil? || segment_text.empty?

          if spans.last && spans.last.source == source
            spans.last.length += segment_text.length
          else
            spans << Span.new(offset, segment_text.length, source)
          end

          offset += segment_text.length
        end

        spans
      end

    end
  end
end
