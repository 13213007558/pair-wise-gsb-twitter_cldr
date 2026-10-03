# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

describe TwitterCldr::Shared::Bidi do
  UNICODE16_TEST_PATH = File.join(File.dirname(__FILE__), 'unicode16_bidi_test.txt')
  DIRECTIONS = [nil, :LTR, :RTL]

  it 'passes the selected Unicode 16 BidiTest isolating-run vectors' do
    expected_levels = []
    expected_reorder = []

    File.foreach(UNICODE16_TEST_PATH) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      if line.start_with?('@Levels:')
        expected_levels = line.split.drop(1)
      elsif line.start_with?('@Reorder:')
        expected_reorder = line.split.drop(1).map(&:to_i)
      else
        input, bitset = line.split('; ')
        types = input.split.map(&:to_sym)
        checks = bitset.to_i.to_s(2).rjust(3, '0').chars.reverse.map { |bit| bit == '1' }

        checks.each_with_index do |enabled, direction_index|
          next unless enabled

          bidi = described_class.from_type_array(
            types, direction: DIRECTIONS[direction_index], default_direction: :LTR
          )
          kept = types.each_index.reject do |index|
            TwitterCldr::Shared::Bidi::EXPLICIT_TYPES.include?(types[index]) || types[index] == :BN
          end

          kept.each do |original_index|
            expected = expected_levels[original_index]
            next if expected == 'x'
            expect(bidi.levels[original_index]).to eq(expected.to_i)
          end

          expected_visible_reorder = expected_reorder.reject do |original_index|
            TwitterCldr::Shared::Bidi::EXPLICIT_TYPES.include?(types[original_index]) ||
              types[original_index] == :BN
          end
          expect(bidi.original_positions[0, kept.size]).to eq(expected_visible_reorder)
        end
      end
    end
  end

  it 'determines FSI direction from its isolate content' do
    bidi = described_class.from_type_array([:R, :WS, :FSI, :L, :PDI, :R])
    expect(bidi.levels).to eq([1, 1, 1, 2, 1, 1])
    expect(bidi.original_positions[0, 4]).to eq([5, 3, 1, 0])

    bidi = described_class.from_type_array([:R, :WS, :FSI, :R, :PDI, :L])
    expect(bidi.levels).to eq([1, 1, 1, 3, 1, 2])
    expect(bidi.original_positions[0, 4]).to eq([5, 3, 1, 0])

    nested = described_class.from_type_array([:FSI, :LRI, :R, :PDI, :PDI])
    expect(nested.levels).to eq([1, 2, 5, 2, 1])
  end

  it 'processes nested isolates and a missing closing PDI' do
    nested = described_class.from_type_array(
      [:R, :LRI, :L, :RLI, :R, :PDI, :L, :PDI, :R]
    )
    expect(nested.levels).to eq([1, 1, 2, 2, 3, 2, 2, 1, 1])
    expect(nested.explicit_levels).to eq([1, 1, 2, 2, 3, 3, 2, 2, 1])
    expect(nested.original_positions[0, 5]).to eq([8, 2, 4, 6, 0])

    missing = described_class.from_type_array([:LRI, :L, :RLI, :R, :LRI, :R])
    expect(missing.levels).to eq([0, 2, 2, 3, 3, 5])
    expect(missing.original_positions[0, 3]).to eq([1, 5, 3])
  end

  it 'defines overflow isolate depth and ignores stray PDIs' do
    types = [:R] + [:LRI] * 126 + [:R]
    bidi = described_class.from_type_array(types)

    expect(bidi.levels[0]).to eq(1)
    expect(bidi.levels[1]).to eq(1)
    expect(bidi.levels[2]).to eq(2)
    expect(bidi.levels[63]).to eq(124)
    expect(bidi.levels[64]).to eq(124)
    expect(bidi.levels[125]).to eq(124)
    expect(bidi.levels[126]).to eq(124)
    expect(bidi.levels[127]).to eq(125)

    closed_types = [:R] + [:LRI] * 126 + [:PDI, :R]
    closed = described_class.from_type_array(closed_types)
    expect(closed.explicit_levels[127]).to eq(125)
    expect(closed.levels[127]).to eq(124)
    expect(closed.levels[128]).to eq(125)
    expect(closed.original_positions[0, 2]).to eq([128, 0])

    stray = described_class.from_type_array([:PDI, :L, :R])
    expect(stray.resolved_levels).to eq([0, 1])
    expect(stray.original_positions[0, 2]).to eq([1, 2])
  end

  it 'keeps adjacent text outside an FSI isolated from its bracketed LTR username' do
    string = "مرحبا \u{2068}(@adam)\u{2069}!"
    bidi = described_class.from_string(string)

    expect(bidi.levels).to eq([
      1, 1, 1, 1, 1, 1,
      1, 2, 2, 2, 2, 2, 2, 2, 1, 1
    ])
    expect(bidi.display_positions).to eq([
      13, 12, 11, 10, 9, 8,
      nil, 1, 2, 3, 4, 5, 6, 7, nil, 0
    ])
    expect(bidi.original_positions[0, 14]).to eq([
      15, 7, 8, 9, 10, 11, 12, 13, 5, 4, 3, 2, 1, 0
    ])

    expect(bidi.reorder_visually!.to_s).to eq('!(@adam) ابحرم')
  end

  it 'pairs Unicode 16 bracket characters across canonical equivalents' do
    bidi = described_class.from_string("مرحبا \u{2067}(0)\u{2069}")
    expect(bidi.resolved_levels).to eq([1, 1, 1, 1, 1, 1, 3, 4, 3])

    bidi = described_class.from_string("مرحبا \u{2067}\u{207D}0\u{207E}\u{2069}")
    expect(bidi.resolved_levels).to eq([1, 1, 1, 1, 1, 1, 3, 4, 3])
  end
end
