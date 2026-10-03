# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Shared
    class Bidi
      EXPLICIT_TYPES = [:LRE, :LRO, :RLE, :RLO, :PDF, :LRI, :RLI, :FSI, :PDI].freeze
      REMOVED_TYPES = (EXPLICIT_TYPES + [:BN]).freeze
      STRONG_TYPES = [:L, :R, :AL].freeze

      MAX_DEPTH = 62
      MAX_EXPLICIT_LEVEL = 125
      MAX_BRACKET_PAIRS = 63

      attr_reader :types, :levels, :explicit_levels, :string_arr

      class << self
        def from_string(str, options = {})
          string_arr = str.unpack("U*")
          new(options.merge(types: compute_types(string_arr), string_arr: string_arr))
        end

        def from_type_array(types, options = {})
          new(options.merge(types: types))
        end

        protected

        def compute_types(arr)
          arr.map { |code_point| CodePoint.get(code_point).bidi_class.to_sym }
        end
      end

      def initialize(options = {})
        @original_types = (options[:types] || []).dup
        @types = @original_types.dup
        @has_string = options.key?(:string_arr)
        @string_arr = options[:string_arr] || @types.map.with_index { |_, index| index }
        @direction = options[:direction]
        @default_direction = options[:default_direction] || :LTR
        @levels = Array.new(@original_types.size)
        @explicit_levels = Array.new(@original_types.size)
        @overridden = {}
        @isolates = {}
        @synthetic = {}
        @logical_to_visual = Array.new(@original_types.size)
        @visual_to_logical = Array.new(@original_types.size)
        @reorder_levels = []
        @reordered = false
        run_bidi
      end

      def to_s
        raise "No string given!" unless @has_string
        return @display_string_arr.pack("U*") if @display_string_arr
        @string_arr.pack("U*")
      end

      def resolved_levels
        visible_indices.map { |index| @levels[index] }
      end

      def display_string_arr
        ensure_reordered
        @display_string_arr.dup
      end

      def display_positions
        ensure_reordered
        @logical_to_visual.dup
      end

      def original_positions
        ensure_reordered
        @visual_to_logical.dup
      end

      def reorder_visually!
        ensure_reordered
        self
      end

      protected

      def run_bidi
        @paragraph_level = paragraph_level
        prepare_isolates
        apply_explicit_levels
        @explicit_levels = @levels.dup
        @isolates.each do |start, info|
          if info[:end_index]
            @explicit_levels[info[:end_index]] = info[:valid] ? info[:level] : MAX_EXPLICIT_LEVEL
          end
        end
        @original_types.each_index do |index|
          next unless @original_types[index] == :PDI
          @explicit_levels[index] ||= current_level_of_removed_pdi(index)
        end
        build_bracket_scopes.each { |scope| resolve_brackets(scope) }
        build_isolating_runs.each { |run| resolve_run(run) }
        resolve_implicit_levels
        assign_position_maps
      end

      def paragraph_level
        if @direction == :LTR
          0
        elsif @direction == :RTL
          1
        else
          @original_types.each do |type|
            return 0 if type == :L
            return 1 if type == :R || type == :AL || type == :RLI || type == :FSI
          end
          @default_direction == :LTR ? 0 : 1
        end
      end

      def prepare_isolates
        @original_types.each_index do |index|
          next unless [:LRI, :RLI, :FSI].include?(@original_types[index])

          finish = matching_pdi(index)
          direction =
            case @original_types[index]
            when :LRI then :LTR
            when :RLI then :RTL
            else fsi_direction(index, finish)
            end

          @isolates[index] = {direction: direction, end_index: finish}
        end
      end

      def matching_pdi(index)
        depth = 0
        position = index + 1

        while position < @original_types.size
          type = @original_types[position]
          if [:LRI, :RLI, :FSI].include?(type)
            depth += 1
          elsif type == :PDI
            return position if depth.zero?
            depth -= 1
          end
          position += 1
        end

        nil
      end

      def fsi_direction(index, finish)
        finish = @original_types.size unless finish
        depth = 0

        (index + 1).upto(finish - 1) do |position|
          type = @original_types[position]
          if [:LRI, :RLI, :FSI].include?(type)
            depth += 1
          elsif type == :PDI && depth.positive?
            depth -= 1
          elsif depth.zero?
            return :LTR if type == :L
            return :RTL if type == :R || type == :AL
          end
        end

        :LTR
      end

      def apply_explicit_levels
        stack = []
        overflow_isolate_count = 0
        overflow_embedding_count = 0
        valid_isolate_count = 0

        @original_types.each_with_index do |type, index|
          case type
          when :RLE, :LRE, :RLO, :LRO
            level = next_level(current_level(stack), type == :LRE || type == :LRO)
            if overflow_isolate_count.zero? && overflow_embedding_count.zero? && level <= MAX_DEPTH
              stack.push(
                level: level,
                previous_level: current_level(stack),
                override: current_override(stack),
                isolate: false
              )
              stack.last[:override] = :L if type == :LRO
              stack.last[:override] = :R if type == :RLO
              @levels[index] = level
            else
              overflow_embedding_count += 1 if overflow_isolate_count.zero?
              @levels[index] = current_level(stack)
            end
            mark_removed(index)
          when :LRI, :RLI, :FSI
            info = @isolates[index]
            outer_level = current_level(stack)
            level = next_isolate_level(outer_level, info[:direction] == :LTR)
            if overflow_isolate_count.zero? && overflow_embedding_count.zero? && level <= MAX_EXPLICIT_LEVEL
              stack.push(
                level: level,
                previous_level: outer_level,
                outer_level: outer_level,
                override: current_override(stack),
                isolate: true
              )
              valid_isolate_count += 1
              info[:valid] = true
              info[:level] = level
              info[:outer_level] = outer_level
              info[:stack_depth] = stack.size
              @levels[index] = outer_level
              @types[index] = info[:direction] == :LTR ? :L : :R
            else
              overflow_isolate_count += 1
              info[:valid] = false
              info[:level] = outer_level
              info[:outer_level] = outer_level
              @levels[index] = outer_level
              @types[index] = info[:direction] == :LTR ? :L : :R
            end
            mark_removed(index)
          when :PDI
            matched = matching_pdi_for_pdi(index)
            if overflow_isolate_count.positive?
              if matched
                depth = isolate_nesting_span(matched, index)
                overflow_isolate_count -= depth
                @levels[index] = current_level(stack)
              else
                @levels[index] = current_level(stack)
              end
            elsif valid_isolate_count.positive?
              while stack.any? && !stack.last[:isolate]
                stack.pop
              end
              stack.pop if stack.any?
              valid_isolate_count -= 1
              overflow_embedding_count = 0
              @levels[index] = current_level(stack)
            else
              @levels[index] = current_level(stack)
            end
            mark_removed(index)
          when :PDF
            if overflow_isolate_count.zero? && overflow_embedding_count.positive?
              overflow_embedding_count -= 1
            elsif stack.any? && !stack.last[:isolate]
              stack.pop
            end
            @levels[index] = current_level(stack)
            mark_removed(index)
          when :BN
            @levels[index] = current_level(stack)
            mark_removed(index)
          else
            @levels[index] = current_level(stack)
            if (override = current_override(stack))
              @overridden[index] = true
              @types[index] = override
            end
          end
        end
      end

      def build_isolating_runs
        runs = []
        append_scope_runs(runs, 0, @original_types.size, @paragraph_level, @paragraph_level, @paragraph_level)
        runs
      end

      def build_bracket_scopes
        @bracket_scopes = build_bracket_scope(0, @original_types.size)[:scopes]
      end

      def build_bracket_scope(start, finish)
        brackets = []
        scopes = []
        index = start

        while index < finish
          type = @original_types[index]
          if [:LRI, :RLI, :FSI].include?(type)
            child_finish = @isolates[index][:end_index]
            child = build_bracket_scope(index + 1, child_finish || finish)
            scopes.concat(child[:scopes])
            brackets.concat(child[:brackets]) unless child_finish
            index = child_finish ? child_finish + 1 : finish
            next
          elsif type == :PDI
            break
          elsif !removed?(index) && bracket_type(index)
            brackets << index
          end

          index += 1
        end

        scopes << brackets unless brackets.empty?
        {scopes: scopes, brackets: brackets}
      end

      def append_scope_runs(runs, start, finish, scope_level, before_level, after_level)
        entries = []
        index = start
        current_level = nil
        current_before_level = before_level

        while index < finish
          type = @original_types[index]

          if [:LRI, :RLI, :FSI].include?(type)
            info = @isolates[index]
            if info[:valid]
              flush_run(runs, entries, current_level, current_before_level, info[:level]) unless entries.empty?
              entries = []
              flush_run(runs, [index], info[:level], scope_level, info[:level])
              @synthetic[index] = true
              child_finish = info[:end_index] || finish
              append_scope_runs(runs, index + 1, child_finish, info[:level], info[:outer_level], info[:level])
              index = info[:end_index] ? child_finish + 1 : child_finish
              current_level = nil
              current_before_level = scope_level
              next
            else
              flush_run(runs, entries, current_level, current_before_level, @levels[index]) unless entries.empty?
              entries = []
              current_level = nil
              flush_run(runs, [index], @levels[index], @levels[index], @levels[index])
              @synthetic[index] = true
              current_before_level = @levels[index]
            end
          elsif type == :PDI
            index += 1
            current_level = nil
            entries = []
            next
          end

          unless removed?(index)
            if current_level.nil?
              current_level = @levels[index]
            elsif @levels[index] != current_level
              previous_level = current_level
              flush_run(runs, entries, previous_level, previous_level, @levels[index])
              entries = []
              current_level = @levels[index]
              current_before_level = previous_level
            end
            entries << index
          end

          index += 1
        end

        flush_run(runs, entries, current_level, current_before_level, after_level) unless entries.empty?
      end

      def flush_run(runs, entries, level, before_level, after_level)
        return if entries.empty?
        runs << {
          indices: entries.dup,
          level: level || before_level,
          before_level: before_level,
          after_level: after_level
        }
      end

      def resolve_run(run)
        indices = run[:indices]
        return if indices.empty?
        level = run[:level]
        sor = [run[:before_level], level].max.even? ? :L : :R
        eor = [level, run[:after_level]].max.even? ? :L : :R
        resolving_indices = indices.reject { |index| @synthetic[index] }
        apply_bracket_numbers(resolved_bracket_pairs(resolving_indices))
        resolve_weak_types(resolving_indices, level, sor, eor)
        resolve_neutral_types(resolving_indices, level, sor, eor)
      end

      def resolve_brackets(indices)
        stack = []
        pairs = []

        indices.each do |index|
          next if @overridden[index] || @synthetic[index]
          bracket = bracket_for(index)
          next unless bracket

          if bracket[:type] == :open
            stack << index if stack.size < MAX_BRACKET_PAIRS
          else
            entry_index = stack.rindex { |open_index| bracket_for(open_index)[:pair] == @string_arr[index] }
            next unless entry_index

            open_index = stack.delete_at(entry_index)
            direction = preceding_bracket_direction(indices, index)
            @types[open_index] = direction
            @types[index] = direction
            pairs << {open: open_index, close: index}
            @resolved_bracket_pairs ||= []
            @resolved_bracket_pairs << pairs.last
          end
        end

        pairs
      end

      def resolved_bracket_pairs(indices)
        (@resolved_bracket_pairs || []).select do |pair|
          indices.include?(pair[:open]) && indices.include?(pair[:close])
        end
      end

      def preceding_bracket_direction(indices, close_index)
        position = indices.index(close_index) - 1

        while position >= 0
          index = indices[position]
          type = @types[index]
          return type if STRONG_TYPES.include?(type)
          position -= 1
        end

        @levels[close_index].even? ? :L : :R
      end

      def apply_bracket_numbers(pairs)
        pairs.each do |pair|
          next unless @types[pair[:open]] == (@levels[pair[:open]].even? ? :L : :R)
          has_strong = (pair[:open] + 1).upto(pair[:close] - 1).any? do |index|
            !removed?(index) && STRONG_TYPES.include?(@types[index])
          end
          next if has_strong

          (pair[:open] + 1).upto(pair[:close] - 1) do |index|
            @types[index] = :AN if @types[index] == :EN
          end
        end
      end

      def resolve_weak_types(indices, level, sor, _eor)
        prev_type = sor
        prev_strong = sor

        indices.each_with_index do |index, position|
          original_type = @original_types[index]

          if @types[index] == :NSM
            @types[index] = prev_type
          else
            prev_type = @types[index]
          end

          if @types[index] == :EN && prev_strong == :AL
            @types[index] = :AN
          end

          @types[index] = :R if @types[index] == :AL

          if position.positive? && position + 1 < indices.size
            previous_index = indices[position - 1]
            next_index = indices[position + 1]
            if [previous_index, index, next_index].all? { |at| @levels[at] == level }
              if @types[previous_index] == :EN && @types[next_index] == :EN && (original_type == :ES || original_type == :CS)
                @types[index] = :EN
              elsif @types[previous_index] == :AN && @types[next_index] == :AN && original_type == :CS
                @types[index] = :AN
              end
            end
          end

          if original_type == :ET
            previous_index = position.zero? ? nil : indices[position - 1]
            if previous_index && @levels[previous_index] == level && @types[previous_index] == :EN
              @types[index] = :EN
            else
              lookahead = position + 1
              while lookahead < indices.size
                candidate = indices[lookahead]
                break unless @levels[candidate] == level && @original_types[candidate] == :ET
                lookahead += 1
              end
              if lookahead < indices.size
                candidate = indices[lookahead]
                if @levels[candidate] == level && @types[candidate] == :EN
                  position.upto(lookahead - 1) { |at| @types[indices[at]] = :EN }
                end
              end
            end
          end

          @types[index] = :ON if [:ES, :ET, :CS].include?(@types[index])
          prev_strong = @types[index] if STRONG_TYPES.include?(@types[index])
          @types[index] = :L if prev_strong == :L && @types[index] == :EN
        end
      end

      def resolve_neutral_types(indices, level, sor, eor)
        prev_strong = sor
        neutral_start = nil

        finish_neutral = lambda do |end_position, strong_type|
          if neutral_start
            resolved = strong_type == prev_strong ? prev_strong : (level.even? ? :L : :R)
            neutral_start.upto(end_position - 1) do |at|
              index = indices[at]
              @types[index] = resolved if neutral_type?(index)
            end
          end
          prev_strong = strong_type if strong_type
          neutral_start = nil
        end

        indices.each_with_index do |index, position|
          type = @types[index]
          if STRONG_TYPES.include?(type) || type == :EN || type == :AN
            finish_neutral.call(position, type == :L ? :L : :R)
          elsif neutral_type?(index)
            neutral_start = position if neutral_start.nil?
          end
        end

        finish_neutral.call(indices.size, eor) if neutral_start
      end

      def neutral_type?(index)
        [:ON, :B, :S, :WS].include?(@types[index]) || @synthetic[index]
      end

      def bracket_type(index)
        bracket = bracket_for(index)
        bracket && bracket[:type]
      end

      def bracket_for(index)
        return unless @has_string
        @bracket_info ||= {}.tap do |brackets|
          opens = code_points_for_property("Open")
          closes = code_points_for_property("Close")
          opens.each_with_index do |code_point, position|
            open_variants = bracket_variants(code_point, opens)
            close_variants = bracket_variants(closes[position], closes)
            open_variants.each do |open|
              close_variants.each do |close|
                brackets[open] = {type: :open, pair: close}
                brackets[close] = {type: :close, pair: open}
              end
            end
          end
        end
        @bracket_info[@string_arr[index]]
      end

      def bracket_variants(code_point, known_set)
        variants = [code_point]
        record = CodePoint.get(code_point)
        decomposition = record && record.decomposition
        if decomposition && decomposition.size == 1 && known_set.include?(decomposition.first)
          variants << decomposition.first
        end
        variants
      end

      def code_points_for_property(value)
        CodePoint.code_points_for_property("Bidi_Paired_Bracket_Type", value).to_full_a
      end

      def resolve_implicit_levels
        @levels.each_with_index do |_level, index|
          next if removed?(index)
          if @levels[index].even?
            @levels[index] += 1 if @types[index] == :R
            @levels[index] += 2 if @types[index] == :AN || @types[index] == :EN
          elsif @types[index] == :L || @types[index] == :AN || @types[index] == :EN
            @levels[index] += 1
          end
        end
        @reorder_levels = @levels.map.with_index do |level, index|
          removed?(index) ? control_reorder_level(index, level) : level
        end
      end

      def control_reorder_level(index, resolved_level)
        if @original_types[index] == :PDI
          matched = matching_pdi_for_pdi(index)
          return matched ? @isolates[matched][:outer_level] : resolved_level || MAX_EXPLICIT_LEVEL
        end
        resolved_level || 0
      end

      def assign_position_maps
        ordered_all = reorder_indices(@original_types.each_index.to_a, @reorder_levels)
        ordered = ordered_all.reject { |index| removed?(index) }
        ordered.each_with_index do |index, visual|
          @logical_to_visual[index] = visual
          @visual_to_logical[visual] = index
        end
      end

      def ensure_reordered
        return if @reordered
        visible = visible_indices
        ordered = @visual_to_logical.map { |index| index unless index.nil? }.compact
        values = ordered.map { |index| @string_arr[index] }
        @display_string_arr = values
        @reordered = true
      end

      def reorder_indices(indices, levels = @levels)
        result = indices.dup
        max_level = result.map { |index| levels[index] }.max || 0
        lowest_odd = result.map { |index| levels[index] }.select(&:odd?).min
        return result unless lowest_odd

        max_level.downto(lowest_odd) do |level|
          start = 0
          while start < result.size
            start += 1 while start < result.size && levels[result[start]] < level
            break if start == result.size
            finish = start + 1
            finish += 1 while finish < result.size && levels[result[finish]] >= level
            ((finish - start) / 2).times do |offset|
              left = start + offset
              right = finish - offset - 1
              break if left >= right
              result[left], result[right] = result[right], result[left]
            end
            start = finish
          end
        end

        result
      end

      def visible_indices
        @original_types.each_index.reject { |index| removed?(index) }
      end

      def next_level(level, ltr)
        ltr ? ((level & ~1) + 2) : ((level + 1) | 1)
      end

      def current_level_of_removed_pdi(_index)
        @paragraph_level
      end

      def next_isolate_level(level, ltr)
        (ltr == level.even?) ? level + 2 : level + 1
      end

      def matching_pdi_for_pdi(index)
        depth = 0
        position = index - 1

        while position >= 0
          type = @original_types[position]
          if type == :PDI
            depth += 1
          elsif [:LRI, :RLI, :FSI].include?(type)
            return position if depth.zero?
            depth -= 1
          end
          position -= 1
        end

        nil
      end

      def isolate_nesting_span(start, finish)
        depth = 0

        start.upto(finish - 1) do |position|
          type = @original_types[position]
          if [:LRI, :RLI, :FSI].include?(type)
            depth += 1
          elsif type == :PDI && depth.positive?
            depth -= 1
          end
        end

        depth
      end

      def current_level(stack)
        stack.empty? ? @paragraph_level : stack.last[:level]
      end

      def current_override(stack)
        stack.empty? ? nil : stack.last[:override]
      end

      def removed?(index)
        REMOVED_TYPES.include?(@original_types[index])
      end

      def mark_removed(index)
        @types[index]
      end
    end
  end
end
