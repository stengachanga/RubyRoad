# frozen_string_literal: true

module Rubyroad
  # Tiny inflection helpers so generated identifiers stay readable.
  # Intentionally small — payment specs do not need ActiveSupport.
  module Inflector
    module_function

    def underscore(value)
      string = value.to_s
      string = string.gsub("::", "/")
      string = string.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
      string = string.gsub(/([a-z\d])([A-Z])/, '\1_\2')
      string.tr("-", "_").downcase
    end

    def camelize(value)
      underscore(value).split(/[_\s.]+/).map { |part| part.capitalize }.join
    end

    def demodulize(value)
      value.to_s.split("::").last
    end

    def singularize(word)
      string = word.to_s
      return string if string.empty?
      return string[0..-4] + "y" if string.end_with?("ies") && string.length > 3
      return string[0..-3] if string.end_with?("ses", "xes", "zes") && string.length > 3
      return string[0..-2] if string.end_with?("s") && !string.end_with?("ss")
      string
    end

    def pluralize(word)
      string = word.to_s
      return string if string.empty? || string.end_with?("s")
      if string.end_with?("y") && string.length > 1 && !"aeiou".include?(string[-2])
        return "#{string[0..-2]}ies"
      end

      "#{string}s"
    end

    def slug(value)
      underscore(value.to_s.gsub(/API\z/i, "")).gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
    end

    def ruby_const(value)
      camelize(slug(value))
    end

    def file_name(value)
      slug(value)
    end

    def ruby_ident(value)
      ident = underscore(value.to_s).gsub(/[^a-z0-9_]/, "_").gsub(/_+\z/, "").gsub(/\A_+/, "")
      ident = "value" if ident.empty?
      ident = "_#{ident}" if ident.match?(/\A\d/)
      ident
    end
  end
end
