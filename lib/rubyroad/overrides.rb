# frozen_string_literal: true

require "json"
require "yaml"

module Rubyroad
  # Generic pin-file for facts that exist only as prose in a spec
  # (amount_unit, required_if, signature_encoding). Not provider-specific.
  class Overrides
    attr_reader :path, :data

    def self.empty
      new({})
    end

    def self.discover(spec, explicit: nil)
      return load(explicit) if explicit && !explicit.to_s.empty?

      path = spec.to_s
      return empty unless File.file?(path)

      base = path.sub(/\.(ya?ml|json)\z/i, "")
      candidate = %W[#{base}.overrides.yaml #{base}.overrides.yml #{base}.overrides.json].find { |file| File.file?(file) }
      candidate ? load(candidate) : empty
    end

    def self.load(path)
      text = File.read(path)
      parsed = if path.to_s.match?(/\.json\z/i)
                 JSON.parse(text)
               else
                 YAML.safe_load(text, permitted_classes: [], aliases: true)
               end
      parsed = {} if parsed.nil?
      raise Error, "overrides #{path} must be a mapping of amount_unit / required_if / signature_encoding" unless parsed.is_a?(Hash)

      new(parsed, path: path)
    end

    def initialize(data, path: nil)
      @data = stringify(data)
      @path = path
    end

    def blank?
      @data.empty?
    end

    def amount_unit
      @data["amount_unit"]&.to_s
    end

    def amount_scale
      scale = @data["amount_scale"]
      scale && Integer(scale)
    end

    def signature_encoding
      enc = @data["signature_encoding"]&.to_s&.downcase
      return enc if %w[hex base64].include?(enc)

      nil
    end

    def signature_payload
      payload = @data["signature_payload"]&.to_s
      return payload if payload && !payload.empty?

      nil
    end

    def signature_algorithm
      algo = @data["signature_algorithm"]&.to_s
      return algo if algo && !algo.empty?

      nil
    end

    def required_if
      Array(@data["required_if"]).filter_map do |rule|
        next unless rule.is_a?(Hash)

        field = (rule["field"] || rule[:field]).to_s
        when_h = stringify(rule["when"] || rule[:when] || {})
        type = (when_h["type"] || when_h[:type]).to_s
        next if field.empty? || type.empty?

        { "field" => field, "when" => { "type" => type } }
      end
    end

    private

    def stringify(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = val.is_a?(Hash) ? stringify(val) : val }
    end
  end
end
