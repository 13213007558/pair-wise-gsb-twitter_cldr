# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Transforms

    # PartialRegexp answers a question Ruby's Regexp engine cannot: given a
    # pattern (expressed as the element list of a Shared::UnicodeRegex) and a
    # buffer, could the match outcome at the end of the buffer still change if
    # more text were appended? In ICU terminology this is a "partial match":
    # some path through the pattern consumed the entire buffer and is waiting
    # for more input, or an end-of-text assertion (e.g. \z) was used.
    #
    # The pattern is compiled into a small NFA (Thompson construction) and
    # simulated over the buffer. Reachability is all that matters, so capture
    # groups and greedy/lazy distinctions are intentionally ignored.
    #
    # This is used by Transforms::Session to decide which part of an
    # incremental transform buffer is final and which part must be retained
    # until more input (or the end of the stream) arrives.
    class PartialRegexp
      class UnsupportedPatternError < StandardError; end

      MAX_REPEAT = 1000

      class << self
        def compile(elements)
          new(elements)
        end

        # Conservative fallback for patterns that cannot be analyzed: they
        # are always treated as if they could still match more input.
        def always_partial
          @always_partial ||= AlwaysPartial.new
        end
      end

      # Singleton used when a pattern cannot be compiled (see .always_partial).
      class AlwaysPartial
        def partial?(_text, _from)
          true
        end
      end

      def initialize(elements)
        ast = AstParser.new(elements).parse
        @code = Compiler.new(ast).compile
      end

      # Returns true if matching the pattern against text[from..-1] could
      # still be affected by text appended later, i.e. if any NFA thread is
      # still alive (or used an end-of-text assertion) after consuming the
      # whole buffer.
      def partial?(text, from)
        size = text.size
        state = { end_used: false }
        list = closure([0], from, text, size, state)
        position = from

        while position < size
          codepoint = text[position].ord
          stepped = []

          list.each do |pc|
            instruction = @code[pc]

            if instruction[0] == :char && char_matches?(instruction[1], codepoint)
              stepped << pc + 1
            end
          end

          return false if stepped.empty?

          position += 1
          list = closure(stepped, position, text, size, state)
        end

        state[:end_used] || list.any? { |pc| @code[pc][0] != :accept }
      end

      private

      def closure(pcs, position, text, size, state)
        list = []
        visited = {}
        stack = pcs.reverse

        until stack.empty?
          pc = stack.pop
          next if visited[pc]
          visited[pc] = true
          instruction = @code[pc]

          case instruction[0]
          when :split
            stack.push(instruction[1], instruction[2])
          when :jmp
            stack.push(instruction[1])
          when :assert
            ok, end_dependent = eval_assert(instruction[1], position, text, size)
            state[:end_used] ||= end_dependent
            stack.push(pc + 1) if ok
          else
            list << pc
          end
        end

        list
      end

      def eval_assert(kind, position, text, size)
        case kind
        when :end
          position == size ? [true, true] : [false, false]
        when :end_or_newline
          if position == size
            [true, true]
          elsif position == size - 1 && text[position] == "\n"
            [true, false]
          else
            [false, false]
          end
        when :dollar
          if position == size
            [true, true]
          elsif text[position] == "\n"
            [true, false]
          else
            [false, false]
          end
        when :start
          [position == 0, false]
        when :caret
          [position == 0 || text[position - 1] == "\n", false]
        when :boundary, :non_boundary
          boundary = word_boundary?(text, position, size)

          if boundary.nil?
            # the following character is unknown, so the assertion cannot be
            # decided yet; conservatively flag it as end-dependent
            [true, true]
          else
            [kind == :boundary ? boundary : !boundary, false]
          end
        else
          [false, false]
        end
      end

      def word_boundary?(text, position, size)
        before = position > 0 && word_char?(text[position - 1])
        return nil if position >= size
        after = word_char?(text[position])
        before != after
      end

      def word_char?(char)
        !!(char =~ /[[:word:]]/)
      end

      def char_matches?(predicate, codepoint)
        if predicate.equal?(:dot)
          codepoint != 10  # Ruby's dot doesn't match newlines by default
        else
          predicate.include?(codepoint)
        end
      end

      # Parses a UnicodeRegex element list into a simple AST. Nodes are
      # arrays of one of these shapes:
      #
      #   [:seq, *children]
      #   [:alt, *children]
      #   [:rep, min, max_or_nil, child]
      #   [:char, rangeset_or_:dot]
      #   [:assert, kind]
      class AstParser
        Parser = TwitterCldr::Parsers::UnicodeRegexParser
        LITERAL = Parser::Literal
        UNICODE_STRING = Parser::UnicodeString
        CHARACTER_CLASS = Parser::CharacterClass

        # escapes that Literal#to_set interprets the same way Ruby's Regexp
        # does (other alphabetic escapes are rejected to stay safe)
        SAFE_ESCAPES = %w(d D w W s S t r n f).freeze

        def initialize(elements)
          @elements = elements
        end

        def parse
          node, index = parse_alternation(0)

          if index != @elements.size
            raise UnsupportedPatternError, 'unexpected trailing pattern elements'
          end

          node
        end

        private

        def parse_alternation(index)
          alternatives = []

          loop do
            node, index = parse_concatenation(index)
            alternatives << node

            if literal_at?(index, '|')
              index += 1
            else
              break
            end
          end

          node = alternatives.size == 1 ? alternatives.first : [:alt, *alternatives]
          [node, index]
        end

        def parse_concatenation(index)
          nodes = []

          until index >= @elements.size ||
                literal_at?(index, ')') ||
                literal_at?(index, '|')
            node, index = parse_piece(index)
            nodes << node
          end

          [[:seq, *nodes], index]
        end

        def parse_piece(index)
          atom, index = parse_atom(index)

          loop do
            element = @elements[index]

            case
            when literal_at?(index, '*')
              atom = [:rep, 0, nil, atom]
              index += 1
            when literal_at?(index, '+')
              atom = [:rep, 1, nil, atom]
              index += 1
            when literal_at?(index, '?')
              atom = [:rep, 0, 1, atom]
              index += 1
            when element.is_a?(LITERAL) && element.text =~ /\A\{(\d+)(?:,(\d*))?\}\z/
              # note: only one- and two-digit counts arrive as single
              # "{n,m}" literals; anything else is literal text, matching
              # how Ruby's Regexp interprets the generated pattern
              min = Regexp.last_match(1).to_i
              max = if Regexp.last_match(2).nil?
                min
              elsif Regexp.last_match(2).empty?
                nil
              else
                Regexp.last_match(2).to_i
              end
              atom = [:rep, min, max, atom]
              index += 1
            else
              break
            end
          end

          [atom, index]
        end

        def parse_atom(index)
          element = @elements[index]

          case element
          when UNICODE_STRING
            [string_node(element.codepoints), index + 1]
          when CHARACTER_CLASS
            [character_class_node(element), index + 1]
          when LITERAL
            literal_node(element, index)
          else
            raise UnsupportedPatternError,
              "unsupported pattern element: #{element.class}"
          end
        end

        def literal_node(element, index)
          case element.text
          when '('
            group_node(index)
          when ')', '|', '*', '+', '?'
            raise UnsupportedPatternError,
              "misplaced '#{element.text}' in pattern"
          when '.'
            [[:char, :dot], index + 1]
          when '$'
            [[:assert, :dollar], index + 1]
          when '^'
            [[:assert, :caret], index + 1]
          when /\A\\(.)\z/m
            escape_node(Regexp.last_match(1), element, index)
          when /\A\{\d+(?:,\d*)?\}\z/
            # a lone repeat operator is treated as literal text by Ruby
            [string_node(element.text.codepoints), index + 1]
          else
            [[:char, char_set(element.text)], index + 1]
          end
        end

        def group_node(index)
          body_start = index + 1

          if literal_at?(body_start, '?')
            modifier = @elements[body_start + 1]

            unless modifier.is_a?(LITERAL) && modifier.text == ':'
              raise UnsupportedPatternError,
                'only non-capturing groups (?:...) are supported'
            end

            body_start += 2
          end

          node, close = parse_alternation(body_start)

          unless literal_at?(close, ')')
            raise UnsupportedPatternError, 'unbalanced group in pattern'
          end

          [node, close + 1]
        end

        def escape_node(char, element, index)
          case char
          when 'z' then [[:assert, :end], index + 1]
          when 'Z' then [[:assert, :end_or_newline], index + 1]
          when 'A' then [[:assert, :start], index + 1]
          when 'b' then [[:assert, :boundary], index + 1]
          when 'B' then [[:assert, :non_boundary], index + 1]
          when 'G'
            raise UnsupportedPatternError, '\\G is not supported'
          when '1'..'9'
            raise UnsupportedPatternError, 'backreferences are not supported'
          when *SAFE_ESCAPES
            [[:char, element.to_set], index + 1]
          else
            if char =~ /[[:alpha:]]/
              raise UnsupportedPatternError, "unsupported escape: \\#{char}"
            else
              [[:char, char_set(char)], index + 1]
            end
          end
        end

        def character_class_node(element)
          ranges = []
          alternatives = []

          element.to_set.to_a(true).each do |entry|
            case entry
            when Range
              if entry.first.is_a?(Array)
                alternatives << string_node(entry.first)
              else
                ranges << entry
              end
            when Array
              alternatives << string_node(entry)
            else
              ranges << (entry..entry)
            end
          end

          nodes = []

          unless ranges.empty?
            nodes << [:char, TwitterCldr::Utils::RangeSet.new(ranges)]
          end

          nodes.concat(alternatives)

          case nodes.size
          when 0
            raise UnsupportedPatternError, 'empty character class'
          when 1
            nodes.first
          else
            [:alt, *nodes]
          end
        end

        def string_node(codepoints)
          [:seq, *codepoints.map { |cp| [:char, codepoint_set(cp)] }]
        end

        def char_set(text)
          TwitterCldr::Utils::RangeSet.from_array(text.codepoints)
        end

        def codepoint_set(codepoint)
          TwitterCldr::Utils::RangeSet.from_array([codepoint])
        end

        def literal_at?(index, text)
          element = @elements[index]
          element.is_a?(LITERAL) && element.text == text
        end
      end

      # Compiles an AST into Pike-VM style instructions:
      #
      #   [:char, predicate]
      #   [:split, pc1, pc2]
      #   [:jmp, pc]
      #   [:assert, kind]
      #   [:accept]
      class Compiler
        def initialize(ast)
          @ast = ast
        end

        def compile
          code = []
          emit(@ast, code)
          code << [:accept]
          code
        end

        private

        def emit(node, code)
          type, *args = node

          case type
          when :seq
            args.each { |child| emit(child, code) }
          when :alt
            emit_alternatives(args, code)
          when :rep
            emit_repeat(args[0], args[1], args[2], code)
          when :char
            code << [:char, args[0]]
          when :assert
            code << [:assert, args[0]]
          else
            raise UnsupportedPatternError, "unknown AST node: #{type}"
          end
        end

        def emit_alternatives(alternatives, code)
          jumps = []

          alternatives.each_with_index do |alternative, idx|
            if idx < alternatives.size - 1
              split = code.size
              code << [:split, nil, nil]
              code[split][1] = code.size
              emit(alternative, code)
              jumps << code.size
              code << [:jmp, nil]
              code[split][2] = code.size
            else
              emit(alternative, code)
            end
          end

          jumps.each { |jump| code[jump][1] = code.size }
        end

        def emit_repeat(min, max, child, code)
          if (min && min > MAX_REPEAT) || (max && max > MAX_REPEAT)
            raise UnsupportedPatternError,
              'bounded repeat is too large to analyze'
          end

          min.times { emit(child, code) }

          if max.nil?
            emit_star(child, code)
          else
            (max - min).times { emit_optional(child, code) }
          end
        end

        def emit_star(child, code)
          split = code.size
          code << [:split, nil, nil]
          code[split][1] = code.size
          emit(child, code)
          code << [:jmp, split]
          code[split][2] = code.size
        end

        def emit_optional(child, code)
          split = code.size
          code << [:split, nil, nil]
          code[split][1] = code.size
          emit(child, code)
          code[split][2] = code.size
        end
      end
    end

  end
end
