# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'fileutils'
require 'open-uri'
require 'yaml'

module TwitterCldr
  module Resources
    # Imports the UTS #39 confusables table (confusables.txt) from the
    # official Unicode security data for the Unicode version that matches
    # the bundled property data (TwitterCldr::Versions.unicode_version).
    #
    # The generated resources/shared/security/confusables.yml maps hex
    # code point sequences to their replacement ("prototype") strings and
    # is consumed by TwitterCldr::Security::Confusables.
    class SecurityDataImporter < Importer
      SECURITY_BASE_URL = 'https://www.unicode.org/Public/security'.freeze
      CONFUSABLES_FILE = 'confusables.txt'.freeze

      output_path 'shared/security'
      ruby_engine :mri

      private

      def execute
        FileUtils.mkdir_p(output_path)

        File.write(
          File.join(output_path, 'confusables.yml'),
          YAML.dump(parse_confusables(fetch_confusables))
        )

        puts "Imported #{CONFUSABLES_FILE} for Unicode #{unicode_version}"
      end

      def output_path
        params.fetch(:output_path)
      end

      def unicode_version
        TwitterCldr::Versions.unicode_version
      end

      def fetch_confusables
        URI.open("#{SECURITY_BASE_URL}/#{unicode_version}/#{CONFUSABLES_FILE}", &:read)
      end

      # Parses lines of the form:
      #
      #   0440 ; 0070 ; MA # ( Cyrillic small letter Er -> Latin p )
      #
      # into a hash of hex code point sequences => replacement strings.
      def parse_confusables(data)
        data.each_line.each_with_object({}) do |line, ret|
          line = line.sub(/#.*$/, '').strip
          next if line.empty?

          source, target, = line.split(';').map(&:strip)
          next unless source && target && !source.empty? && !target.empty?

          ret[source] = decode(target)
        end
      end

      def decode(hex_sequence)
        hex_sequence.split(' ').map { |hex| hex.to_i(16) }.pack('U*')
      end
    end
  end
end
