# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

# Bidirectional paired bracket mapping used by UAX #9 rule BD16.
# Generated from BidiBrackets.txt for the Unicode version shipped with this
# gem (see Versions.unicode_version).  Regenerate with
# BidiPairedBracketsImporter.

module TwitterCldr
  module Shared
    module Properties
      module BidiPairedBrackets
        OPEN_TO_CLOSE = {
          0x0028 => 0x0029,
          0x005B => 0x005D,
          0x007B => 0x007D,
          0x0F3A => 0x0F3B,
          0x0F3C => 0x0F3D,
          0x169B => 0x169C,
          0x2045 => 0x2046,
          0x207D => 0x207E,
          0x208D => 0x208E,
          0x2308 => 0x2309,
          0x230A => 0x230B,
          0x2329 => 0x232A,
          0x2768 => 0x2769,
          0x276A => 0x276B,
          0x276C => 0x276D,
          0x276E => 0x276F,
          0x2770 => 0x2771,
          0x2772 => 0x2773,
          0x2774 => 0x2775,
          0x27C5 => 0x27C6,
          0x27E6 => 0x27E7,
          0x27E8 => 0x27E9,
          0x27EA => 0x27EB,
          0x27EC => 0x27ED,
          0x27EE => 0x27EF,
          0x2983 => 0x2984,
          0x2985 => 0x2986,
          0x2987 => 0x2988,
          0x2989 => 0x298A,
          0x298B => 0x298C,
          0x298D => 0x298E,
          0x298F => 0x2990,
          0x2991 => 0x2992,
          0x2993 => 0x2994,
          0x2995 => 0x2996,
          0x2997 => 0x2998,
          0x29D8 => 0x29D9,
          0x29DA => 0x29DB,
          0x29FC => 0x29FD,
          0x2E22 => 0x2E23,
          0x2E24 => 0x2E25,
          0x2E26 => 0x2E27,
          0x2E28 => 0x2E29,
          0x2E55 => 0x2E56,
          0x2E57 => 0x2E58,
          0x2E59 => 0x2E5A,
          0x2E5B => 0x2E5C,
          0x3008 => 0x3009,
          0x300A => 0x300B,
          0x300C => 0x300D,
          0x300E => 0x300F,
          0x3010 => 0x3011,
          0x3014 => 0x3015,
          0x3016 => 0x3017,
          0x3018 => 0x3019,
          0x301A => 0x301B,
          0xFE59 => 0xFE5A,
          0xFE5B => 0xFE5C,
          0xFE5D => 0xFE5E,
          0xFF08 => 0xFF09,
          0xFF3B => 0xFF3D,
          0xFF5B => 0xFF5D,
          0xFF5F => 0xFF60,
          0xFF62 => 0xFF63,
        }.freeze

        CLOSE_TO_OPEN = OPEN_TO_CLOSE.each_with_object({}) do |(open, close), memo|
          memo[close] = open
        end.freeze

        class << self
          def close_for_open(code_point)
            OPEN_TO_CLOSE[code_point]
          end

          def open_for_close(code_point)
            CLOSE_TO_OPEN[code_point]
          end

          def paired?(code_point)
            OPEN_TO_CLOSE.key?(code_point) || CLOSE_TO_OPEN.key?(code_point)
          end

          def opening?(code_point)
            OPEN_TO_CLOSE.key?(code_point)
          end

          def closing?(code_point)
            CLOSE_TO_OPEN.key?(code_point)
          end
        end
      end
    end
  end
end
