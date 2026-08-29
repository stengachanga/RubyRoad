# frozen_string_literal: true

require "date"
require "json"
require "yaml"
require "uri"
require "net/http"
require "openssl"
require "pathname"

module Rubyroad
  # Loads an OpenAPI 3.x document from a file path or HTTP(S) URL,
  # then resolves local `$ref` pointers so the analyzer can walk schemas.
  class SpecLoader
    MAX_BYTES = 8 * 1024 * 1024
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def self.load(path_or_url)
      new(path_or_url).load
    end

    def initialize(path_or_url)
      @source = path_or_url.to_s.strip
      raise SpecLoadError, "SPEC_PATH is required (file or http(s) URL)" if @source.empty?
    end

    def load
      raw = fetch(@source)
      data = parse(raw)
      validate!(data)
      RefResolver.new(data).document
    end

    private

    def fetch(source)
      if url?(source)
        fetch_url(source)
      else
        fetch_file(source)
      end
    end

    def url?(source)
      source.match?(%r{\Ahttps?://}i)
    end

    def fetch_file(path)
      expanded = File.expand_path(path)
      unless File.file?(expanded)
        raise SpecLoadError, "OpenAPI spec not found: #{path}"
      end

      File.read(expanded, encoding: "UTF-8")
    rescue Errno::ENOENT
      raise SpecLoadError, "OpenAPI spec not found: #{path}"
    end

    def fetch_url(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTP)
        raise SpecLoadError, "Only http(s) URLs are supported: #{url}"
      end

      response = http_get(uri)
      unless response.is_a?(Net::HTTPSuccess)
        raise SpecLoadError,
              "Failed to download spec from #{url}: HTTP #{response.code} #{response.message}"
      end

      body = response.body.to_s
      if body.bytesize > MAX_BYTES
        raise SpecLoadError, "Spec from #{url} is larger than #{MAX_BYTES} bytes"
      end

      body
    rescue SpecLoadError
      raise
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise SpecLoadError, "Failed to download spec from #{url}: #{e.class}: #{e.message}"
    rescue URI::InvalidURIError => e
      raise SpecLoadError, "Invalid spec URL #{url}: #{e.message}"
    end

    def http_get(uri, redirects = 0)
      raise SpecLoadError, "Too many redirects fetching #{uri}" if redirects > 5

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "RubyRoad/#{VERSION}"
      request["Accept"] = "application/yaml, text/yaml, application/json, text/plain, */*"

      response = http.request(request)
      if response.is_a?(Net::HTTPRedirection) && response["location"]
        return http_get(URI.join(uri, response["location"]), redirects + 1)
      end

      response
    end

    def parse(raw)
      strip = raw.sub(/\A\uFEFF/, "")
      if looks_like_json?(strip)
        JSON.parse(strip)
      else
        YAML.safe_load(strip, permitted_classes: [Date, Time], aliases: true)
      end
    rescue Psych::SyntaxError, JSON::ParserError => e
      raise InvalidSpecError, "Failed to parse OpenAPI document: #{e.message}"
    end

    def looks_like_json?(raw)
      raw.lstrip.start_with?("{", "[")
    end

    def validate!(data)
      unless data.is_a?(Hash)
        raise InvalidSpecError, "OpenAPI document must be a YAML/JSON object, not #{data.class}"
      end

      version = data["openapi"] || data["swagger"]
      if version.nil?
        raise InvalidSpecError,
              "Not a valid OpenAPI 3.x specification: missing 'openapi' field. " \
              "If this is Swagger 2.0, convert it to OpenAPI 3 first."
      end

      unless version.to_s.match?(/\A3\.\d+/)
        raise InvalidSpecError,
              "Unsupported OpenAPI version #{version.inspect} (need 3.0 or 3.1). " \
              "Swagger 2.0 / OpenAPI 2.x is not supported."
      end

      info = data["info"]
      unless info.is_a?(Hash) && info["title"].to_s.strip != ""
        raise InvalidSpecError, "Invalid OpenAPI spec: info.title is required"
      end

      unless data["paths"].is_a?(Hash) || data["webhooks"].is_a?(Hash)
        raise InvalidSpecError, "Invalid OpenAPI spec: expected a 'paths' or 'webhooks' object"
      end
    end
  end

  # Resolves `#/…` JSON Pointer refs in-place while preserving the original
  # `$ref` as `x-rubyroad-ref` so model names survive flattening.
  class RefResolver
    def initialize(document)
      @document = document
      @cache = {}
    end

    def document
      walk(@document, [])
      @document
    end

    def lookup(ref)
      return @cache[ref] if @cache.key?(ref)

      raise InvalidSpecError, "Only local $ref pointers are supported (got #{ref.inspect})" unless ref.start_with?("#/")

      parts = ref[2..].split("/").map { |part| unescape(part) }
      node = @document
      parts.each do |part|
        node = node.is_a?(Hash) ? node[part] : nil
        if node.nil?
          raise InvalidSpecError, "Unresolvable $ref: #{ref}"
        end
      end
      @cache[ref] = node
    end

    private

    def walk(node, stack)
      case node
      when Hash
        if node["$ref"].is_a?(String) && node["$ref"].start_with?("#/")
          ref = node["$ref"]
          if stack.include?(ref)
            node["x-rubyroad-ref"] ||= ref
            return
          end
          target = dup_node(lookup(ref))
          node["x-rubyroad-ref"] = ref
          extras = node.each_with_object({}) do |(key, value), acc|
            acc[key] = value unless key == "$ref" || key == "x-rubyroad-ref"
          end
          node.clear
          merge_hash(node, target)
          merge_hash(node, extras)
          node["x-rubyroad-ref"] = ref
          walk(node, stack + [ref])
        else
          node.each_value { |child| walk(child, stack) }
        end
      when Array
        node.each { |child| walk(child, stack) }
      end
    end

    def dup_node(node)
      case node
      when Hash
        node.each_with_object({}) { |(k, v), acc| acc[k] = dup_node(v) }
      when Array
        node.map { |v| dup_node(v) }
      else
        node
      end
    end

    def merge_hash(into, from)
      from.each do |key, value|
        into[key] = value unless into.key?(key)
      end
    end

    def unescape(part)
      part.gsub("~1", "/").gsub("~0", "~")
    end
  end
end
