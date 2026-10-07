# encoding: UTF-8

# Copyright 2012 Twitter, Inc
# http://www.apache.org/licenses/LICENSE-2.0

require 'nokogiri'
require 'fileutils'
require 'set'

module TwitterCldr
  module Resources

    # Imports CLDR number range data into a single shared resource:
    #
    #   resources/shared/number_ranges.yml
    #
    # Two kinds of data are captured:
    #
    #   * miscPattern[@type="interval"] - the locale-tailored fallback
    #     range pattern per number system/type (decimal, percent,
    #     currency);
    #   * intervalPattern[@fallback] - plural range rules, keyed by the
    #     plural categories of the two endpoints.
    #
    # Locale inheritance resolution is delegated to CLDR's own build
    # process, so only locale-tailored patterns are persisted here; runtime
    # locale fallback is handled by TwitterCldr::Shared::NumberRanges.
    class NumberRangesImporter < Importer

      requirement :cldr, Versions.cldr_version
      output_path 'shared/number_ranges.yml'
      ruby_engine :mri

      TYPES = %w(decimal percent currency).freeze

      private

      def execute
        result = supported_locale_data
        result[:root] = root_data

        FileUtils.mkdir_p(File.dirname(output_file))
        File.open(output_file, 'w:utf-8') do |output|
          output.write(
            TwitterCldr::Utils::YAML.dump(
              TwitterCldr::Utils.deep_symbolize_keys(result),
              use_natural_symbols: true
            )
          )
        end
      end

      def supported_locale_data
        TwitterCldr.supported_locales.each_with_object({}) do |locale, ret|
          data = NumberRanges.new(locale, requirements[:cldr]).to_h
          ret[locale] = data unless data.empty?
        end
      end

      def root_data
        NumberRanges.new(:root, requirements[:cldr]).to_h
      end

      def output_file
        params.fetch(:output_path)
      end

    end

    class NumberRanges

      attr_reader :locale, :cldr_req

      def initialize(locale, cldr_req)
        @locale = locale
        @cldr_req = cldr_req
      end

      def to_h
        patterns = fallback_patterns
        plural_ranges = plural_range_rules
        return {} if patterns.empty? && plural_ranges.empty?

        data = {}
        data[:patterns] = patterns unless patterns.empty?
        data[:plural_ranges] = plural_ranges unless plural_ranges.empty?
        data
      end

      private

      def fallback_patterns
        NumberRangesImporter::TYPES.each_with_object({}) do |type, ret|
          node = doc.at_xpath(
            "//ldml/numbers/miscPatterns/miscPattern[@type='interval' and @numberSystem='latn' and @numberType='#{type}']"
          )
          ret[type.to_sym] = node.content if node && !cldr_req.draft?(node)
        end
      end

      def plural_range_rules
        doc.xpath("//ldml/numbers/ranges/intervalPatternGroup/intervalPattern[@fallback]")
           .each_with_object({}) do |node, ret|
          next if cldr_req.draft?(node)

          left_rule = node.attribute('fallback').value
          right_rule = node.attribute('count')&.value || 'other'
          ret[left_rule.to_sym] ||= {}
          ret[left_rule.to_sym][right_rule.to_sym] = node.content
        end
      end

      def doc
        @doc ||= begin
          locale_fs = locale.to_s.gsub('-', '_')
          file = File.join(cldr_req.common_path, 'main', "#{locale_fs}.xml")
          Nokogiri.XML(File.read(file))
        end
      end

    end
  end
end
