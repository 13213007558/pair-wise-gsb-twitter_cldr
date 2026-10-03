# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'spec_helper'

OFFICIAL_TEST_PATH = File.join(File.dirname(__FILE__), 'BidiTest-14.0.0.txt')
DIRECTIONS = [nil, :LTR, :RTL]

describe TwitterCldr::Shared::Bidi do
  def parse_official_tokens(input)
    input.split(' ').map do |token|
      case token
      when '(o' then :Bidi_Open
      when 'c)' then :Bidi_Close
      else token.to_sym
      end
    end
  end

  it 'passes the curated Unicode 14.0.0 BidiTest.txt vectors' do
    expected_levels = nil
    expected_reorder = nil
    checked = 0

    File.foreach(OFFICIAL_TEST_PATH) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      if line.start_with?('@Levels:')
        expected_levels = line.split[1..].map(&:to_i)
      elsif line.start_with?('@Reorder:')
        expected_reorder = line.split[1..].map(&:to_i)
      else
        input, bitset = line.split(';')
        types = parse_official_tokens(input)

        3.times do |bit|
          next unless bitset.to_i & (1 << bit) > 0
          bidi = described_class.from_type_array(types, direction: DIRECTIONS[bit])

          expect(bidi.levels).to eq(expected_levels),
            "levels for #{input} [#{DIRECTIONS[bit] || :auto}]"
          expect(bidi.visual_order).to eq(expected_reorder),
            "reorder for #{input} [#{DIRECTIONS[bit] || :auto}]"
          checked += 1
        end
      end
    end

    expect(checked).to be > 0
  end

  describe 'directional isolates' do
    let(:fsi) { [0x2068].pack('U') }
    let(:pdi) { [0x2069].pack('U') }
    let(:alef) { [0x0627].pack('U') }

    it 'resolves FSI to an L isolate when its content is L (rule X5c)' do
      bidi = described_class.from_string("#{alef}#{fsi}ab#{pdi}#{alef}")
      expect(bidi.levels).to eq([1, 1, 2, 2, 1, 1])
    end

    it 'resolves FSI to an R isolate when its content is AL (rule X5c)' do
      bidi = described_class.from_string("#{alef}#{fsi}#{alef}#{pdi}#{alef}")
      expect(bidi.levels).to eq([1, 1, 3, 1, 1])
    end

    it 'runs an isolate with a missing PDI to the end of the paragraph (X6a)' do
      bidi = described_class.from_type_array([:LRI, :L, :L])
      expect(bidi.levels).to eq([0, 2, 2])
      expect(bidi.visual_order).to eq([2, 1])
    end

    it 'keeps a PDI without an initiator at the current embedding level (X6c)' do
      bidi = described_class.from_type_array([:R, :PDI, :R])
      expect(bidi.levels).to eq([1, 1, 1])
      expect(bidi.visual_order).to eq([2, 0])
    end

    it 'does not let a PDF pop across an isolate boundary (rule X7)' do
      bidi = described_class.from_type_array(
        [:L, :RLE, :LRI, :R, :PDF, :PDI, :L]
      )
      expect(bidi.levels).to eq([0, 0, 1, 3, 2, 1, 2])
    end

    it 'nests LRI and RLI isolates and matches PDIs' do
      bidi = described_class.from_type_array(
        [:R, :LRI, :L, :RLI, :R, :PDI, :PDI, :R]
      )
      expect(bidi.levels).to eq([1, 1, 2, 2, 3, 2, 1, 1])
      expect(bidi.visual_order).to eq([7, 4, 2, 0])
    end
  end

  describe 'explicit depth overflow (BD2)' do
    it 'ignores pushes past level 62 and still balances valid PDFs' do
      controls = Array.new(32, :LRO)
      types = [:L] + controls + [:R] + Array.new(32, :PDF) + [:L]
      bidi = described_class.from_type_array(types, direction: :LTR)

      expect(bidi.levels.max).to eq(62)
      expect(bidi.levels.first).to eq(0)
      expect(bidi.levels.last).to eq(0)
    end
  end

  describe 'Arabic text with an isolated parenthesized English username' do
    let(:fsi) { [0x2068].pack('U') }
    let(:pdi) { [0x2069].pack('U') }
    let(:username) { '(john_123)' }
    let(:string) do
      "\u0645\u0631\u062d\u0628\u0627 #{fsi}#{username}#{pdi}: \u0639\u0627\u0644\u0645"
    end

    it 'keeps the username and its brackets on one even LTR level' do
      bidi = described_class.from_string(string)
      code_points = string.unpack('U*')
      user_indices = (code_points.index(0x28)..code_points.index(0x29)).to_a

      expect(user_indices.map { |i| bidi.levels[i] }).to all(eq(2))
      expect(bidi.levels[code_points.index(0x3A)]).to eq(1)
    end

    it 'does not let outside punctuation inherit the isolate direction' do
      bidi = described_class.from_string(string)
      code_points = string.unpack('U*')
      colon = code_points.index(0x3A)

      expect(bidi.display_positions[colon]).to be < bidi.display_positions[code_points.index(0x29)]
    end

    it 'provides inverse logical/display position maps' do
      bidi = described_class.from_string(string)
      order = bidi.visual_order

      expect(order.map { |logical| bidi.display_positions[logical] }).to eq((0...order.size).to_a)
      expect(bidi.display_positions[code_point(string, 0x2068)]).to be_nil
      expect(bidi.display_positions[code_point(string, 0x2069)]).to be_nil
    end

    it 'keeps the username characters as one contiguous unit in display order' do
      bidi = described_class.from_string(string)
      code_points = string.unpack('U*')
      start = code_points.index(0x28)
      finish = code_points.index(0x29)
      positions = (start..finish).map { |index| bidi.display_positions[index] }

      expect(positions.max - positions.min).to eq(finish - start)
      expect(bidi.levels[start..finish]).to all(eq(2))
    end

    def code_point(string, code)
      string.unpack('U*').index(code)
    end
  end

  describe 'paired brackets (BD16/N0)' do
    it 'propagates a strong R inside a matched bracket pair on the same run' do
      bidi = described_class.from_type_array([:L, :Bidi_Open, :R, :Bidi_Close, :L])
      expect(bidi.levels).to eq([0, 1, 1, 1, 0])
      expect(bidi.visual_order).to eq([0, 3, 2, 1, 4])
    end
  end
end
