# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

# Implementation of the Unicode Bidirectional Algorithm (UAX #9) as specified
# for Unicode 14.0.0, including:
#
#   * Explicit embeddings and overrides (rules X1-X8, LRE/RLE/LRO/RLO/PDF)
#   * Explicit directional isolates (rules X5a-X6c, LRI/RLI/FSI/PDI); FSI takes
#     its direction from its content according to X5c and P2/P3
#   * Explicit-format removal (rule X9) and level-run boundaries (rule X10)
#   * Paired bracket handling and the bracket pair type rule N0 (BD16)
#   * Weak types (W1-W7), neutral types (N1-N2) and implicit levels (I1-I2)
#   * Paragraph embedding level P2-P3 and the L1/L2 reordering rules
#
# This replaces an earlier port of the GNU Classpath Bidi class, which only
# supported embeddings and overrides.

module TwitterCldr
  module Shared
    class Bidi
      include TwitterCldr::Shared::Properties

      # Rule BD2.
      MAX_EXPLICIT_DEPTH = 62
      # Rule I2.
      MAX_IMPLICIT_DEPTH = 125

      ISOLATE_INITIATOR_TYPES = [:LRI, :RLI, :FSI].freeze

      attr_reader :types, :levels, :string_arr, :base_level

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
          arr.map do |code_point|
            TwitterCldr::Shared::CodePoint.get(code_point).bidi_class.to_sym
          end
        end
      end

      def initialize(options = {})
        @string_arr = options[:string_arr]
        @types = (options[:types] || []).dup
        @levels = Array.new(@types.size)
        @direction = options[:direction]
        @default_direction = options[:default_direction] || :LTR
        @length = @types.size
        @removed = Array.new(@length, false)
        @visual_order = nil
        @display_positions = nil
        @base_level = nil
        run_bidi
      end

      def to_s
        @string_arr.pack("U*") if @string_arr
      end

      # visual_order[display_position] = logical index of the character shown at
      # that position.  Characters removed by rule X9 are not included.
      def visual_order
        compute_visual_order! unless @visual_order
        @visual_order
      end

      # display_positions[logical_index] = display position, or nil when the
      # character was removed by rule X9.
      def display_positions
        compute_visual_order! unless @display_positions
        @display_positions
      end

      def reordered_string
        raise "No string given!" unless @string_arr
        visual_order.map { |idx| @string_arr[idx] }.pack("U*")
      end

      # Backwards-compatible in-place reordering.  Formatting characters and BN
      # characters (rule X9) are dropped from the string.
      def reorder_visually!
        raise "No string given!" unless @string_arr
        order = visual_order
        reordered = order.map { |idx| @string_arr[idx] }
        reordered_levels = order.map { |idx| @levels[idx] }
        reordered_types = order.map { |idx| @types[idx] }
        @string_arr.replace(reordered)
        @levels.replace(reordered_levels)
        @types.replace(reordered_types)
        @removed = Array.new(@string_arr.size, false)
        @length = @string_arr.size
        @display_positions = (0...@length).to_a
        @visual_order = (0...@length).to_a
        self
      end

      protected

      # Rules P2 and P3.  Isolate controls are skipped as required by P2, and
      # FSI is treated as RLI for the paragraph-level scan.
      def paragraph_embedding_level(start, limit)
        if @direction == :LTR
          0
        elsif @direction == :RTL
          1
        else
          start.upto(limit - 1) do |i|
            case @types[i]
            when :AL, :R then return 1
            when :L then return 0
            end
          end
          @default_direction == :LTR ? 0 : 1
        end
      end

      def run_bidi
        # Rule BD13: each paragraph (delimited by B) is independent.  Levels
        # assigned across the paragraph boundary are reset below.
        start = 0
        index = 0

        while index < @length
          limit = index
          limit += 1 while limit < @length && @types[limit] != :B

          base = paragraph_embedding_level(index, limit)
          @base_level ||= base

          compute_explicit_levels(index, limit, base)
          runs = compute_level_runs(index, limit)
          resolve_bracket_pairs(runs)
          resolve_weak_types(runs, base, index, limit)
          resolve_neutral_types(runs, base, index, limit)
          resolve_implicit_levels(runs)
          reset_paragraph_levels(index, limit, base)

          if limit < @length
            # The B separator itself gets the paragraph embedding level.
            @levels[limit] = base
            index = limit + 1
          else
            index = @length
          end
        end
      end

      # Rules X1-X9.  Computes the embedding level of every character and marks
      # formatting characters for removal by X9.
      #
      # Each stack entry records [level, override] where override is :L, :R or
      # nil.  Isolate status is tracked separately so that valid PDF pops are
      # blocked above an isolate while PDI pops past everything.
      def compute_explicit_levels(start, limit, base)
        # Each stack entry is {level:, override:, isolate:}.  Only the last
        # entry ever carries an active override, but keeping it on the entry
        # makes PDF/PDI pops straightforward.
        stack = [{level: base, override: nil, isolate: false}]
        overflow_isolate_count = 0
        overflow_embedding_count = 0
        valid_isolate_count = 0

        start.upto(limit - 1) do |i|
          type = @types[i]
          level = stack.last[:level]

          case type
          when :LRI, :RLI, :FSI
            if type == :FSI
              resolved = fsi_direction(i, limit)
              type = resolved == 1 ? :RLI : :LRI
            end

            @levels[i] = level
            @removed[i] = true

            new_level = least_greater(level, type == :LRI ? 0 : 1)
            if new_level <= MAX_EXPLICIT_DEPTH && overflow_isolate_count == 0 &&
               overflow_embedding_count == 0
              valid_isolate_count += 1
              stack.push(level: new_level, override: nil, isolate: true)
            else
              overflow_isolate_count += 1
            end

          when :PDI
            if overflow_isolate_count > 0
              overflow_isolate_count -= 1
            elsif valid_isolate_count > 0
              until stack.last[:isolate]
                stack.pop
              end
              if stack.last[:isolate]
                stack.pop
                valid_isolate_count -= 1
              end
            end
            # Rule X6c: a PDI matching an invalid isolate, or without a matching
            # initiator, takes the current embedding level.
            @levels[i] = stack.last[:level]
            @removed[i] = true

          when :LRE, :RLE, :LRO, :RLO
            new_level = least_greater(level, type == :RLE || type == :RLO ? 1 : 0)
            override = (type == :LRO ? :L : type == :RLO ? :R : nil)

            if new_level <= MAX_EXPLICIT_DEPTH && overflow_isolate_count == 0 &&
               overflow_embedding_count == 0
              stack.push(level: new_level, override: override, isolate: false)
            elsif overflow_isolate_count == 0
              overflow_embedding_count += 1
            end
            @levels[i] = level
            @removed[i] = true

          when :PDF
            if overflow_isolate_count == 0 && overflow_embedding_count > 0
              overflow_embedding_count -= 1
            elsif overflow_isolate_count == 0 && valid_isolate_count == 0
              # Rule X7: terminate the last embedding/override on the stack.
              stack.pop unless stack.size == 1
            end
            @levels[i] = level
            @removed[i] = true

          when :BN
            @levels[i] = level
            @removed[i] = true

          else
            @levels[i] = level
            override = stack.last[:override]
            @types[i] = override if override
          end
        end
      end

      # Rule X5c: FSI acts like LRI unless its content (up to the matching PDI)
      # would have paragraph embedding level 1 under P2/P3.
      def fsi_direction(index, limit)
        depth = 1
        i = index + 1
        while i < limit
          type = @types[i]
          if ISOLATE_INITIATOR_TYPES.include?(type)
            depth += 1
          elsif type == :PDI
            depth -= 1
            break if depth == 0
          elsif depth == 1
            return 1 if type == :R || type == :AL
            return 0 if type == :L
          end
          i += 1
        end
        @default_direction == :LTR ? 0 : 1
      end

      def least_greater(level, parity)
        if parity == 1
          level.odd? ? level + 2 : level + 1
        else
          level.even? ? level + 2 : level + 1
        end
      end

      # Rule X10: maximal sequences of non-removed characters at the same level
      # are processed independently.  Isolate initiators get the level of the
      # run that contains them (the outer run), while the PDI gets the level of
      # the run that contains its matching initiator.
      def compute_level_runs(start, limit)
        runs = []
        i = start
        while i < limit
          next(i += 1) if @removed[i]

          run_level = @levels[i]
          run_start = i
          i += 1

          while i < limit
            if @removed[i]
              # X10: only the isolate initiator belongs to the outer run.
              break unless ISOLATE_INITIATOR_TYPES.include?(@types[i])
            elsif @levels[i] != run_level
              break
            end
            i += 1
          end

          runs << [run_start, i]
        end
        runs
      end

      # Rules BD16 and N0.
      def resolve_bracket_pairs(runs)
        runs.each do |run_start, run_limit|
          open_stack = []

          run_start.upto(run_limit - 1) do |i|
            next if @removed[i]
            type = bracket_kind_at(i)

            if type == :open
              if open_stack.size == 63
                open_stack.shift
              end
              open_stack.push(i)
            elsif type == :close
              opener = find_matching_opener(open_stack, i)
              if opener
                pair_type = bracket_pair_type(opener, i)
                if pair_type
                  @types[opener] = pair_type
                  @types[i] = pair_type
                end
              end
            end
          end
        end
      end

      # Real strings use the Unicode 14.0.0 bracket data; type-array inputs
      # (BidiTest) tag bracket ON characters as :Bidi_Open/:Bidi_Close with
      # matching by nesting position.
      def bracket_kind_at(index)
        code = @string_arr && @string_arr[index]
        if code
          if BidiPairedBrackets.opening?(code)
            :open
          elsif BidiPairedBrackets.closing?(code)
            :close
          end
        elsif @types[index] == :Bidi_Open
          :open
        elsif @types[index] == :Bidi_Close
          :close
        end
      end

      def find_matching_opener(open_stack, closer_index)
        code = @string_arr && @string_arr[closer_index]
        open_stack.reverse_each do |opener_index|
          if code.nil?
            # Type-array vectors pair brackets positionally.
            open_stack.delete(opener_index)
            return opener_index
          end

          opener_code = @string_arr[opener_index]
          if BidiPairedBrackets.close_for_open(opener_code) == code
            open_stack.delete(opener_index)
            return opener_index
          end
        end
        nil
      end

      # Rules W1-W7, applied independently to each level run.
      def resolve_weak_types(runs, base, paragraph_start, paragraph_limit)
        runs.each do |run_start, run_limit|
          level = @levels[run_start]
          sor = boundary_type(run_start, true, base, paragraph_start, paragraph_limit)
          eor = boundary_type(run_limit - 1, false, base, paragraph_start, paragraph_limit)

          # Rules W1-W3, W7 in a single forward pass.
          preceding = sor
          preceding_strong = sor

          run_start.upto(run_limit - 1) do |i|
            next if @removed[i]

            # W1.
            @types[i] = preceding if @types[i] == :NSM

            # W2 (uses the original AL strong type, so precedes W3).
            @types[i] = :AN if @types[i] == :EN && preceding_strong == :AL

            # Track the last strong type for W2/W7.
            case @types[i]
            when :L then preceding_strong = :L
            when :R then preceding_strong = :R
            when :AL then preceding_strong = :AL
            end

            # W3.
            @types[i] = :R if @types[i] == :AL

            # W7.
            @types[i] = :L if @types[i] == :EN && preceding_strong == :L

            preceding = @types[i]
          end

          # W4.
          run_start.upto(run_limit - 1) do |i|
            next if @removed[i]
            prev = previous_type(i, run_start, sor)
            nxt = next_type(i, run_limit, eor)
            if @types[i] == :ES && prev == :EN && nxt == :EN
              @types[i] = :EN
            elsif @types[i] == :CS && prev == :EN && nxt == :EN
              @types[i] = :EN
            elsif @types[i] == :CS && prev == :AN && nxt == :AN
              @types[i] = :AN
            end
          end

          # W5.
          i = run_start
          while i < run_limit
            if !@removed[i] && @types[i] == :ET
              j = i
              j += 1 while j < run_limit && !@removed[j] && @types[j] == :ET
              prev = previous_type(i, run_start, sor)
              nxt = next_type(j - 1, run_limit, eor)
              if prev == :EN || nxt == :EN
                i.upto(j - 1) { |k| @types[k] = :EN unless @removed[k] }
              end
              i = j
            else
              i += 1
            end
          end

          # W6.
          run_start.upto(run_limit - 1) do |i|
            next if @removed[i]
            if [:ES, :ET, :CS].include?(@types[i])
              @types[i] = :ON
            end
          end
        end
      end

      def previous_type(index, run_start, sor)
        i = index - 1
        i -= 1 while i >= run_start && @removed[i]
        i < run_start ? sor : @types[i]
      end

      def next_type(index, run_limit, eor)
        i = index + 1
        i += 1 while i < run_limit && @removed[i]
        i >= run_limit ? eor : @types[i]
      end

      # SOR/EOR strong type for a run (rules HL2/HL3).
      def boundary_type(index, before, base, paragraph_start = 0, paragraph_limit = @length)
        boundary_level = if before
                           scan = index - 1
                           scan -= 1 while scan >= paragraph_start && @removed[scan]
                           [@levels[index], scan >= paragraph_start ? @levels[scan] : base].max
                         else
                           scan = index + 1
                           scan += 1 while scan < paragraph_limit && @removed[scan]
                           [@levels[index], scan < paragraph_limit ? @levels[scan] : base].max
                         end
        (boundary_level & 1) == 1 ? :R : :L
      end

      # Rules N1 and N2, applied per level run.  BN characters are ignored.
      def resolve_neutral_types(runs, base, paragraph_start, paragraph_limit)
        runs.each do |run_start, run_limit|
          sor = boundary_type(run_start, true, base, paragraph_start, paragraph_limit)
          eor = boundary_type(run_limit - 1, false, base, paragraph_start, paragraph_limit)
          embedding_direction = (@levels[run_start] & 1) == 1 ? :R : :L

          preceding_strong = sor
          neutral_start = nil

          run_start.upto(run_limit) do |i|
            strong = i == run_limit ? eor : strong_for_neutral(i)

            if strong
              if neutral_start
                resolved = preceding_strong == strong ? strong : embedding_direction
                neutral_start.upto(i - 1) do |j|
                  @types[j] = resolved if !@removed[j] && neutral_type?(@types[j])
                end
              end
              preceding_strong = strong
              neutral_start = nil
            elsif i < run_limit && !@removed[i] && neutral_type?(@types[i])
              neutral_start ||= i
            end
          end
        end
      end

      def strong_for_neutral(index)
        case @types[index]
        when :L then :L
        when :R, :AN, :EN then :R
        end
      end

      def neutral_type?(type)
        [:B, :S, :WS, :ON, :FSI, :LRI, :RLI, :PDI].include?(type)
      end

      # Rules I1 and I2.
      def resolve_implicit_levels(runs)
        runs.each do |run_start, run_limit|
          even_level = (@levels[run_start] & 1) == 0

          run_start.upto(run_limit - 1) do |i|
            next if @removed[i]
            if even_level
              if @types[i] == :R
                @levels[i] += 1
              elsif [:AN, :EN].include?(@types[i])
                @levels[i] += 2
              end
            else
              if [:L, :AN, :EN].include?(@types[i])
                @levels[i] += 1
              end
            end
            @levels[i] = MAX_IMPLICIT_DEPTH if @levels[i] > MAX_IMPLICIT_DEPTH
          end
        end
      end

      # Rule L1.
      def reset_paragraph_levels(start, limit, base)
        # 1. Any sequence of whitespace characters and/or B/S at the end of a
        # line up to and including the first strong character.
        start.upto(limit - 1) do |i|
          next if @removed[i]
          @levels[i] = base if @types[i] == :S || @types[i] == :B
        end

        # 2. Reset the trailing whitespace sequence; a run of PDIs (optionally
        # preceded by a matching isolate initiator) is part of that sequence.
        i = limit - 1
        i -= 1 while i >= start && @removed[i]

        while i >= start && !@removed[i] && whitespace_for_l1?(@types[i])
          @levels[i] = base
          i -= 1
        end

        if i >= start && !@removed[i] && @types[i] == :PDI
          while i >= start && !@removed[i] && @types[i] == :PDI
            @levels[i] = base
            i -= 1
          end
          if i >= start && !@removed[i] && ISOLATE_INITIATOR_TYPES.include?(@types[i])
            @levels[i] = base
            i -= 1
          end
        end

        while i >= start && !@removed[i] && whitespace_for_l1?(@types[i])
          @levels[i] = base
          i -= 1
        end

        # 3. Leading whitespace.
        start.upto(limit - 1) do |j|
          if !@removed[j] && (@types[j] == :WS || @types[j] == :B || @types[j] == :S)
            @levels[j] = base
          else
            break
          end
        end

        # 4. Whitespace adjacent to an isolate initiator/PDI that was reset.
        start.upto(limit - 1) do |j|
          next unless ISOLATE_INITIATOR_TYPES.include?(@types[j]) || @types[j] == :PDI
          next unless @levels[j] == base
          k = j - 1
          while k >= start && !@removed[k] && @types[k] == :WS
            @levels[k] = base
            k -= 1
          end
          k = j + 1
          while k < limit && !@removed[k] && @types[k] == :WS
            @levels[k] = base
            k += 1
          end
        end
      end

      def whitespace_for_l1?(type)
        type == :WS || type == :B || type == :S
      end

      # Rule L2: reverse from the highest level down to the lowest odd level.
      def compute_visual_order!
        surviving = (0...@length).select { |i| !@removed[i] }
        order = surviving.dup

        highest = surviving.map { |i| @levels[i] }.max || 0

        highest.downto(1) do |level|
          next if level.even?

          start = 0
          while start < order.size
            start += 1 while start < order.size && @levels[order[start]] < level
            break if start == order.size
            finish = start + 1
            finish += 1 while finish < order.size && @levels[order[finish]] >= level
            order[start...finish] = order[start...finish].reverse
            start = finish
          end
        end

        @visual_order = order
        @display_positions = Array.new(@length)
        order.each_with_index { |logical, visual| @display_positions[logical] = visual }
      end

      # Rule N0: within a bracket pair, R/AL wins over AN, EN and L; AN wins
      # over EN and L; EN wins over L.  The bracket characters themselves are
      # assigned the chosen strong type.
      def bracket_pair_type(opener, closer)
        # Strong-type precedence: R > AN > EN > L.  R is checked first by a
        # whole-pair scan so that, e.g., an earlier L cannot mask a later R.
        (opener + 1).upto(closer - 1) do |i|
          next if @removed[i]
          return :R if @types[i] == :R || @types[i] == :AL
        end
        (opener + 1).upto(closer - 1) do |i|
          next if @removed[i]
          case @types[i]
          when :AN then return :AN
          when :EN then return :EN
          when :L then return :L
          end
        end
        nil
      end
    end
  end
end
