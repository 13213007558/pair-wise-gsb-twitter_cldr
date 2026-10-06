# encoding: UTF-8

module TwitterCldr
  module Transforms
    class PartialRegexp
      Analysis = Struct.new(:partial_source, :max_size, :unbounded) do
        def unbounded?
          unbounded
        end
      end

      attr_reader :source

      def initialize(source)
        @source = source || ''
      end

      def to_regexp
        Regexp.new("\\G(?:#{analysis.partial_source})\\z")
      rescue RegexpError
        /.*/m
      end

      def max_size
        analysis.max_size || 0
      end

      def unbounded?
        analysis.unbounded
      end

      private

      def analysis
        @analysis ||= begin
          node = Parser.new(source).parse
          Analysis.new(node.partial_source, node.max_size, node.unbounded?)
        end
      end

      class Parser
        Node = Struct.new(:inner_source, :partial_source, :max_size, :zero_width?, :unbounded) do
          def unbounded?
            !!unbounded
          end
        end

        def initialize(source)
          @source = source
          @position = 0
        end

        def parse
          parse_alternation
        end

        private

        def parse_alternation
          alternatives = [parse_sequence]

          while consume('|')
            alternatives << parse_sequence
          end

          build_alternation(alternatives)
        end

        def parse_sequence
          nodes = []

          while atom_starts?
            nodes << parse_quantified
          end

          build_sequence(nodes)
        end

        def parse_quantified
          node = parse_atom
          quantifier = parse_quantifier
          return node unless quantifier

          minimum, maximum, possessive = quantifier
          partial = if maximum
            "(?:#{node.partial_source}){0,#{maximum}}"
          else
            "(?:#{node.partial_source})*"
          end

          inner = "(?:#{node.inner_source})#{quantifier_source(minimum, maximum)}"
          inner << '?' if possessive == :lazy
          inner << '+' if possessive == :possessive

          unbounded = maximum.nil? && !node.zero_width?
          max_size = if node.zero_width?
            0
          elsif maximum && node.max_size
            node.max_size * maximum
          end

          Node.new(inner, partial, max_size, node.zero_width?, unbounded)
        end

        def parse_quantifier
          case peek
            when '?'
              advance
              [0, 1, consume_modifier]
            when '*'
              advance
              [0, nil, consume_modifier]
            when '+'
              advance
              [1, nil, consume_modifier]
            when '{'
              parse_braced_quantifier
          end
        end

        def parse_braced_quantifier
          start = @position
          advance
          minimum = read_number
          return rewind(start) unless minimum

          maximum = minimum

          if consume(',')
            number = read_number
            maximum = number
          end

          return rewind(start) unless consume('}')
          [minimum, maximum, consume_modifier]
        end

        def consume_modifier
          case peek
            when '?' then advance && :lazy
            when '+' then advance && :possessive
          end
        end

        def quantifier_source(minimum, maximum)
          if minimum == 0 && maximum == 1
            '?'
          elsif minimum.zero? && maximum.nil?
            '*'
          elsif minimum == 1 && maximum.nil?
            '+'
          elsif minimum == maximum
            "{#{minimum}}"
          elsif maximum.nil?
            "{#{minimum},}"
          else
            "{#{minimum},#{maximum}}"
          end
        end

        def parse_atom
          case peek
            when '(' then parse_group
            when '[' then parse_character_class
            when '\\' then parse_escape
            when '^', '$' then parse_anchor
            else parse_literal
          end
        end

        def parse_group
          start = @position
          advance
          specifier = ''
          assertion = nil

          if consume('?')
            case peek
              when ':' then advance
              when '=' then advance && assertion = :positive_lookahead
              when '!' then advance && assertion = :negative_lookahead
              when '<'
                advance
                case peek
                  when '=' then advance && assertion = :lookbehind
                  when '!' then advance && assertion = :negative_lookbehind
                  else
                    name = read_until('>')
                    consume('>')
                    specifier = "<#{name}>"
                end
              when '#'
                skip_comment
                return empty_node
              else specifier = read_options
            end
          end

          return empty_node if assertion == :comment

          node = parse_alternation
          consume(')')
          raw = @source[start...@position]

          case assertion
            when :positive_lookahead
              Node.new(raw, "(?=#{node.partial_source})", 0, true)
            when :negative_lookahead, :lookbehind, :negative_lookbehind
              Node.new(raw, raw, 0, true)
            else
              inner = "(#{specifier}#{node.inner_source})"
              partial = "(#{specifier}#{node.partial_source})"
              Node.new(inner, partial, node.max_size, node.zero_width?)
          end
        end

        def parse_character_class
          start = @position
          advance

          consume('^')

          until eos? || peek == ']'
            if peek == '[' && @source[@position + 1] == ':'
              advance
              advance until eos? || peek == ':' && @source[@position + 1] == ']'
              advance
              advance
            elsif peek == '\\'
              parse_escape
            else
              advance
            end
          end

          consume(']')
          literal(@source[start...@position])
        end

        def parse_escape
          start = @position
          advance
          advance

          if peek == '{'
            advance
            advance until eos? || peek == '}'
            consume('}')
          end

          raw = @source[start...@position]

          case raw
            when '\\A', '\\z', '\\Z', '\\b', '\\B', '\\G'
              Node.new(raw, raw, 0, true)
            else
              literal(raw)
          end
        end

        def parse_anchor
          raw = advance
          Node.new(raw, raw, 0, true)
        end

        def parse_literal
          raw = advance
          raw ? literal(raw) : empty_node
        end

        def skip_comment
          depth = 1

          until depth.zero? || eos?
            case advance
              when '(' then depth += 1
              when ')' then depth -= 1
            end
          end

          :comment
        end

        def read_options
          options = '?'

          while /[[:alpha:]-:]/.match?(peek.to_s)
            options << advance
          end

          options
        end

        def read_until(character)
          value = ''
          value << advance until eos? || peek == character
          value
        end

        def build_alternation(nodes)
          inner = nodes.map(&:inner_source).join('|')
          partial = nodes.map(&:partial_source).join('|')
          max_size = nodes.map(&:max_size).compact.max
          zero_width = nodes.all?(&:zero_width?)
          Node.new("(?:#{inner})", "(?:#{partial})", max_size, zero_width, nodes.any?(&:unbounded?))
        end

        def build_sequence(nodes)
          if nodes.empty?
            empty_node
          else
            Node.new(
              nodes.map(&:inner_source).join,
              combine_sequence_partials(nodes),
              nodes.map(&:max_size).compact.sum,
              nodes.all?(&:zero_width?),
              nodes.any?(&:unbounded?)
            )
          end
        end

        def combine_sequence_partials(nodes)
          nodes.each_with_index.map do |node, index|
            prefix = index.zero? ? '' : nodes[0...index].map(&:inner_source).join
            "#{prefix}(?:#{node.inner_source}|#{node.partial_source})"
          end.join('|')
        end

        def literal(source)
          Node.new(source, source, 1, false, false)
        end

        def empty_node
          Node.new('', '', 0, true, false)
        end

        def atom_starts?
          !eos? && peek != ')' && peek != '|' && !peek.match?(/[?*+]/)
        end

        def read_number
          start = @position
          advance while /[0-9]/.match?(peek.to_s)
          number = @source[start...@position]
          number.empty? ? nil : number.to_i
        end

        def consume(expected)
          return false unless peek == expected
          advance
          true
        end

        def rewind(position)
          @position = position
          nil
        end

        def advance
          return if eos?
          character = @source[@position]
          @position += 1
          character
        end

        def peek
          @source[@position]
        end

        def eos?
          @position >= @source.size
        end
      end
    end
  end
end
