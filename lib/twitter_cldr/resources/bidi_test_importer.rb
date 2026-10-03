# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

module TwitterCldr
  module Resources
    # Fetches the official UAX #9 conformance vectors (BidiTest.txt) for the
    # Unicode version shipped with this gem and stores them under spec/bidi.
    # The Bidi class is expected to pass every case in that file; the curated
    # BidiTest-14.0.0.txt shipped in the repository covers the same syntax.
    class BidiTestImporter < Importer
      BIDI_TEST_FILE = 'ucd/BidiTest.txt'
      OUT_FILE = 'BidiTest.txt'

      requirement :unicode, Versions.unicode_version, [BIDI_TEST_FILE]
      output_path File.join(TwitterCldr::SPEC_DIR, 'bidi')
      ruby_engine :mri

      def execute
        FileUtils.cp(source_file, output_file)
      end

      private

      def source_file
        requirements[:unicode].source_path_for(BIDI_TEST_FILE)
      end

      def output_file
        File.join(params.fetch(:output_path), OUT_FILE)
      end
    end
  end
end
