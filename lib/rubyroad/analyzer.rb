# frozen_string_literal: true

require "uri"

module Rubyroad
  Parameter = Struct.new(
    :name,
    :ruby_name,
    :in,
    :required,
    :type,
    :format,
    :description,
    :example,
    :enum,
    :schema,
    keyword_init: true
  )

  Property = Struct.new(
    :name,
    :ruby_name,
    :type,
    :format,
    :required,
    :description,
    :example,
    :enum,
    :money,
    :ref_name,
    :schema,
    keyword_init: true
  )

  SchemaModel = Struct.new(
    :name,
    :const_name,
    :description,
    :properties,
    :money_like,
    :list,
    :item_const,
    :example,
    :raw,
    keyword_init: true
  )

  Operation = Struct.new(
    :operation_id,
    :method_name,
    :http_method,
    :path,
    :summary,
    :description,
    :tags,
    :resource,
    :path_params,
    :query_params,
    :header_params,
    :body_properties,
    :has_request_body,
    :request_example,
    :success_status,
    :success_schema_name,
    :success_const,
    :success_example,
    :success_is_list,
    :success_item_const,
    :error_status,
    :error_example,
    :has_idempotency,
    :idempotency_header,
    :fixture_name,
    :request_examples,
    :response_examples,
    keyword_init: true
  )

  SecurityScheme = Struct.new(
    :key,
    :type,
    :scheme,
    :header_name,
    :in,
    :description,
    :bearer_format,
    keyword_init: true
  )

  WebhookEvent = Struct.new(
    :name,
    :type,
    :description,
    :example,
    keyword_init: true
  )

  # Turns a resolved OpenAPI 3.x document into a generation-friendly model.
  class Analyzer
    HTTP_VERBS = %w[get put post delete options head patch trace].freeze
    MONEY_AMOUNT_KEYS = %w[amount cents amount_cents value minor_units].freeze
    MONEY_CURRENCY_KEYS = %w[currency currency_code iso_currency].freeze
    PAYMENT_RESOURCES = %w[payment charge refund customer invoice payout webhook subscription].freeze

    def initialize(document, name: nil)
      @doc = document
      @forced_name = name
    end

    def analyze
      Analysis.new(
        raw: @doc,
        gem_name: gem_name,
        module_name: module_name,
        provider_slug: gem_name,
        title: title,
        version: version,
        description: description,
        sandbox_url: sandbox_url,
        live_url: live_url,
        operations: operations,
        schemas: schemas,
        security_schemes: security_schemes,
        default_security: default_security,
        has_webhooks: webhook_events.any? || webhook_documented?,
        webhook_events: webhook_events,
        webhook_header: webhook_header,
        webhook_algorithm: webhook_algorithm,
        webhook_format: webhook_format,
        has_idempotency: operations.any?(&:has_idempotency),
        idempotency_header: idempotency_header,
        preferred_auth: preferred_auth
      )
    end

    private

    def info
      @doc["info"] || {}
    end

    def title
      info["title"].to_s.strip
    end

    def version
      info["version"].to_s.strip
    end

    def description
      info["description"].to_s.strip
    end

    def gem_name
      return Inflector.slug(@forced_name) if @forced_name && !@forced_name.to_s.strip.empty?

      from_title = Inflector.slug(title)
      return from_title unless from_title.empty?

      host = begin
        URI.parse(sandbox_url).host
      rescue URI::InvalidURIError
        nil
      end
      Inflector.slug(host || "provider")
    end

    def module_name
      Inflector.camelize(gem_name)
    end

    def servers
      Array(@doc["servers"])
    end

    def sandbox_url
      match = servers.find { |server| server["description"].to_s.match?(/sandbox|test|dev/i) }
      url_of(match || servers.first) || "https://api.example.test/v1"
    end

    def live_url
      match = servers.find { |server| server["description"].to_s.match?(/live|prod|production/i) }
      url_of(match || servers.last || servers.first) || sandbox_url
    end

    def url_of(server)
      return nil unless server.is_a?(Hash)

      server["url"].to_s.sub(%r{/\z}, "")
    end

    def security_schemes
      @security_schemes ||= begin
        raw = @doc.dig("components", "securitySchemes") || {}
        raw.map do |key, scheme|
          SecurityScheme.new(
            key: key,
            type: scheme["type"].to_s,
            scheme: scheme["scheme"].to_s,
            header_name: scheme["name"].to_s,
            in: scheme["in"].to_s,
            description: scheme["description"].to_s,
            bearer_format: scheme["bearerFormat"].to_s
          )
        end
      end
    end

    def default_security
      Array(@doc["security"]).flat_map(&:keys)
    end

    def preferred_auth
      keys = default_security
      schemes = security_schemes
      chosen = schemes.find { |s| keys.include?(s.key) } || schemes.first
      return { kind: :bearer, header: "Authorization", key: "bearerAuth" } unless chosen

      if chosen.type == "http" && chosen.scheme.downcase == "basic"
        { kind: :basic, header: "Authorization", key: chosen.key }
      elsif chosen.type == "apiKey" && chosen.in == "header"
        { kind: :api_key, header: chosen.header_name.empty? ? "X-API-Key" : chosen.header_name, key: chosen.key }
      elsif chosen.type == "oauth2" || chosen.type == "openIdConnect"
        { kind: :unsupported, header: "Authorization", key: chosen.key, type: chosen.type }
      else
        { kind: :bearer, header: "Authorization", key: chosen.key }
      end
    end

    def schemas
      @schemas ||= begin
        raw = @doc.dig("components", "schemas") || {}
        raw.filter_map do |name, schema|
          next unless schema.is_a?(Hash)
          next if schema["type"] && !%w[object array].include?(schema["type"]) && schema["properties"].nil?

          flattened = flatten_schema(schema)
          props = properties_of(flattened)
          list = flattened["type"] == "array" || (flattened.dig("properties", "data", "type") == "array")
          item_ref = if flattened["type"] == "array"
                       ref_name(flattened["items"])
                     else
                       ref_name(flattened.dig("properties", "data", "items"))
                     end
          SchemaModel.new(
            name: name,
            const_name: Inflector.camelize(name),
            description: flattened["description"].to_s,
            properties: props,
            money_like: money_like?(props),
            list: list,
            item_const: item_ref && Inflector.camelize(item_ref),
            example: flattened["example"] || synthesize_example(flattened),
            raw: flattened
          )
        end
      end
    end

    def operations
      @operations ||= begin
        ops = []
        paths = @doc["paths"] || {}
        paths.each do |path, item|
          next unless item.is_a?(Hash)

          shared = Array(item["parameters"])
          HTTP_VERBS.each do |verb|
            operation = item[verb]
            next unless operation.is_a?(Hash)

            ops << build_operation(verb, path, operation, shared)
          end
        end
        ops
      end
    end

    def build_operation(verb, path, operation, shared_params)
      params = (shared_params + Array(operation["parameters"])).map { |p| build_parameter(p) }
      path_params = params.select { |p| p.in == "path" }
      query_params = params.select { |p| p.in == "query" }
      header_params = params.select { |p| p.in == "header" }
      idempotency = header_params.find { |p| p.name.match?(/idempotency/i) }

      body_schema = request_schema(operation)
      body_props = body_schema ? properties_of(body_schema) : []
      request_example = request_example_of(operation) || (body_schema && synthesize_example(body_schema))

      success_status, success = success_response(operation)
      success_schema = success && content_schema(success)
      success_example = (success && content_example(success)) || (success_schema && synthesize_example(success_schema))
      success_name = schema_name(success_schema) || infer_success_name(path, verb, success_schema)
      list = list_schema?(success_schema)
      item_const = list ? list_item_const(success_schema) : nil

      error_status, error = error_response(operation)
      error_example = error && (content_example(error) || default_error_example)

      method_name = method_name_for(operation, verb, path)
      resource = resource_for(operation, path)

      Operation.new(
        operation_id: operation["operationId"].to_s,
        method_name: method_name,
        http_method: verb,
        path: path,
        summary: operation["summary"].to_s,
        description: operation["description"].to_s,
        tags: Array(operation["tags"]),
        resource: resource,
        path_params: path_params,
        query_params: query_params,
        header_params: header_params.reject { |p| p.name.match?(/idempotency/i) },
        body_properties: body_props,
        has_request_body: !body_schema.nil?,
        request_example: request_example,
        success_status: success_status,
        success_schema_name: success_name,
        success_const: success_name && Inflector.camelize(success_name),
        success_example: success_example,
        success_is_list: list,
        success_item_const: item_const,
        error_status: error_status,
        error_example: error_example,
        has_idempotency: !idempotency.nil? || idempotency_mentioned?(operation),
        idempotency_header: (idempotency && idempotency.name) || idempotency_header,
        fixture_name: Inflector.underscore(method_name),
        request_examples: named_examples_from(operation["requestBody"]),
        response_examples: response_examples_from(operation)
      )
    end

    def build_parameter(raw)
      schema = raw["schema"].is_a?(Hash) ? raw["schema"] : {}
      example = raw["example"] || schema["example"] || (schema["enum"].is_a?(Array) && schema["enum"].first)
      name = raw["name"].to_s
      Parameter.new(
        name: name,
        ruby_name: Inflector.ruby_ident(name),
        in: raw["in"].to_s,
        required: raw["required"] == true || raw["in"].to_s == "path",
        type: schema["type"].to_s,
        format: schema["format"].to_s,
        description: raw["description"].to_s,
        example: example.nil? ? default_example_for(name, schema["type"]) : example,
        enum: Array(schema["enum"]),
        schema: schema
      )
    end

    def request_schema(operation)
      body = operation["requestBody"]
      return nil unless body.is_a?(Hash)

      content_schema(body)
    end

    def request_example_of(operation)
      body = operation["requestBody"]
      return nil unless body.is_a?(Hash)

      content_example(body)
    end

    def content_schema(object)
      content = object["content"]
      return object["schema"] if object["schema"].is_a?(Hash)
      return nil unless content.is_a?(Hash)

      media = content["application/json"] || content.values.find { |v| v.is_a?(Hash) }
      media.is_a?(Hash) ? media["schema"] : nil
    end

    def content_example(object)
      content = object["content"]
      return object["example"] if object.key?("example")
      return nil unless content.is_a?(Hash)

      media = content["application/json"] || content.values.find { |v| v.is_a?(Hash) }
      return nil unless media.is_a?(Hash)
      return media["example"] if media.key?("example")

      examples = media["examples"]
      if examples.is_a?(Hash) && examples.any?
        first = examples.values.first
        return first["value"] if first.is_a?(Hash) && first.key?("value")
        return first
      end

      schema = media["schema"]
      schema.is_a?(Hash) ? schema["example"] : nil
    end

    def success_response(operation)
      responses = operation["responses"] || {}
      pick = %w[200 201 202 204].find { |code| responses[code] }
      pick ||= responses.keys.find { |code| code.to_s.start_with?("2") }
      return ["200", {}] unless pick

      [pick.to_s.to_i, responses[pick]]
    end

    def error_response(operation)
      responses = operation["responses"] || {}
      pick = %w[400 402 401 403 404 409 422 429 500].find { |code| responses[code] }
      pick ||= responses.keys.find { |code| code.to_s.start_with?("4", "5") }
      return [400, nil] unless pick

      [pick.to_s.to_i, responses[pick]]
    end

    def method_name_for(operation, verb, path)
      if operation["operationId"].to_s.strip != ""
        return Inflector.ruby_ident(operation["operationId"])
      end

      segments = static_segments(path)
      last = segments.last || "resource"
      nested = segments.length > 1
        item = path.match?(/\{[^}]+\}\z/)

      prefix =
        case verb
        when "get"
          item || (nested && path.include?("{")) ? "retrieve" : "list"
        when "post"
          "create"
        when "put", "patch"
          "update"
        when "delete"
          "delete"
        else
          verb
        end

      noun =
        if prefix == "list"
          Inflector.pluralize(Inflector.singularize(last))
        elsif prefix == "create" && !item && last.end_with?("s")
          Inflector.singularize(last)
        else
          Inflector.singularize(last)
        end

      "#{prefix}_#{Inflector.ruby_ident(noun)}"
    end

    def resource_for(operation, path)
      tag = Array(operation["tags"]).first
      return Inflector.slug(tag) if tag

      static_segments(path).first || "general"
    end

    def static_segments(path)
      path.split("/").reject { |part| part.empty? || part.start_with?("{") }
    end

    def infer_success_name(path, verb, schema)
      named = schema_name(schema)
      return named if named

      last = static_segments(path).last || "Result"
        if verb == "get" && !path.match?(/\{[^}]+\}\z/)
        "#{Inflector.camelize(Inflector.singularize(last))}List"
      else
        Inflector.camelize(Inflector.singularize(last))
      end
    end

    def schema_name(schema)
      return nil unless schema.is_a?(Hash)

      ref = schema["x-rubyroad-ref"].to_s
      if (match = ref.match(%r{#/components/schemas/([^/]+)\z}))
        return match[1]
      end

      schema["title"]
    end

    def ref_name(schema)
      return nil unless schema.is_a?(Hash)

      schema_name(schema)
    end

    def list_schema?(schema)
      return false unless schema.is_a?(Hash)
      return true if schema["type"] == "array"
      return true if schema.dig("properties", "data", "type") == "array"

      false
    end

    def list_item_const(schema)
      return nil unless schema.is_a?(Hash)

      items = schema["type"] == "array" ? schema["items"] : schema.dig("properties", "data", "items")
      name = ref_name(items)
      name && Inflector.camelize(name)
    end

    def flatten_schema(schema)
      return {} unless schema.is_a?(Hash)

      if schema["allOf"].is_a?(Array)
        merged = { "type" => "object", "properties" => {}, "required" => [] }
        schema["allOf"].each do |part|
          part = flatten_schema(part)
          (merged["properties"] ||= {}).merge!(part["properties"] || {})
          merged["required"] |= Array(part["required"])
          merged["description"] ||= part["description"]
          merged["example"] ||= part["example"]
          merged["x-rubyroad-ref"] ||= part["x-rubyroad-ref"]
        end
        extras = schema.dup
        extras.delete("allOf")
        merge_schema(merged, extras)
        return merged
      end

      schema
    end

    def merge_schema(into, from)
      from.each do |key, value|
        if key == "properties" && value.is_a?(Hash)
          into["properties"] = (into["properties"] || {}).merge(value)
        elsif key == "required" && value.is_a?(Array)
          into["required"] = Array(into["required"]) | value
        else
          into[key] = value unless into.key?(key)
        end
      end
    end

    def properties_of(schema)
      schema = flatten_schema(schema)
      props = schema["properties"] || {}
      required = Array(schema["required"])
      props.map do |name, prop|
        prop = flatten_schema(prop.is_a?(Hash) ? prop : {})
        Property.new(
          name: name,
          ruby_name: Inflector.ruby_ident(name),
          type: prop["type"].to_s,
          format: prop["format"].to_s,
          required: required.include?(name),
          description: prop["description"].to_s,
          example: prop["example"] || (prop["enum"].is_a?(Array) && prop["enum"].first),
          enum: Array(prop["enum"]),
          money: money_property?(name, prop),
          ref_name: schema_name(prop),
          schema: prop
        )
      end
    end

    def money_property?(name, schema)
      return true if MONEY_AMOUNT_KEYS.include?(name.to_s) && %w[integer int64 int32].include?(schema["type"].to_s)
      return true if schema["format"].to_s.match?(/money|amount|minor/i)

      false
    end

    def money_like?(properties)
      names = properties.map(&:name)
      (names & MONEY_AMOUNT_KEYS).any? && (names & MONEY_CURRENCY_KEYS).any?
    end

    def synthesize_example(schema, depth = 0)
      return nil if schema.nil? || depth > 6
      return schema["example"] if schema.is_a?(Hash) && schema.key?("example")
      return nil unless schema.is_a?(Hash)

      schema = flatten_schema(schema)
      if schema["enum"].is_a?(Array) && schema["enum"].any?
        return schema["enum"].first
      end

      case schema["type"]
      when "object", nil
        return {} unless schema["properties"].is_a?(Hash) || schema["type"] == "object"

        (schema["properties"] || {}).each_with_object({}) do |(name, prop), acc|
          acc[name] = synthesize_example(prop.is_a?(Hash) ? prop : {}, depth + 1)
        end
      when "array"
        item = synthesize_example(schema["items"].is_a?(Hash) ? schema["items"] : {}, depth + 1)
        [item]
      when "integer", "int32", "int64"
        schema["example"] || (MONEY_AMOUNT_KEYS.include?(schema["title"].to_s.downcase) ? 2500 : 1)
      when "number"
        # Payment amounts must never be floats in generated code; still emit an
        # integer-looking number so fixtures stay money-safe.
        schema["example"] || 1
      when "boolean"
        true
      when "string"
        case schema["format"]
        when "date-time" then "2026-08-29T14:00:00Z"
        when "date" then "2026-08-29"
        when "email" then "merchant@example.com"
        when "uuid" then "00000000-0000-4000-8000-000000000001"
        when "uri", "url" then "https://example.com/callback"
        else
          schema["example"] || "example"
        end
      else
        schema["example"]
      end
    end

    def default_example_for(name, type)
      case type
      when "integer" then name.match?(/limit|page|count/i) ? 10 : 1
      when "boolean" then false
      else
        if name.match?(/id\z/i)
          "#{Inflector.slug(name).split('_').first}_test_123"
        elsif name.match?(/email/i)
          "merchant@example.com"
        elsif name.match?(/currency/i)
          "USD"
        else
          "example"
        end
      end
    end

    def named_examples_from(object)
      return {} unless object.is_a?(Hash)

      content = object["content"]
      media = content.is_a?(Hash) ? (content["application/json"] || content.values.find { |v| v.is_a?(Hash) }) : nil
      examples = media.is_a?(Hash) ? media["examples"] : nil
      return {} unless examples.is_a?(Hash)

      examples.each_with_object({}) do |(name, example), acc|
        value = example.is_a?(Hash) && example.key?("value") ? example["value"] : example
        acc[name.to_s] = value
      end
    end

    def response_examples_from(operation)
      responses = operation["responses"] || {}
      responses.each_with_object({}) do |(status, response), acc|
        example = content_example(response)
        acc[status.to_s] = example if example
      end
    end

    def default_error_example
      {
        "error" => {
          "type" => "invalid_request",
          "code" => "parameter_invalid",
          "message" => "The request could not be processed.",
          "param" => "amount"
        }
      }
    end

    def idempotency_header
      "Idempotency-Key"
    end

    def idempotency_mentioned?(operation)
      blob = operation.to_s
      blob.match?(/Idempotency-Key/i)
    end

    def webhook_documented?
      @doc["webhooks"].is_a?(Hash) && !@doc["webhooks"].empty? ||
        operations_have_callbacks? ||
        (@doc["paths"] || {}).keys.any? { |path| path.to_s.match?(/webhook/i) }
    end

    def operations_have_callbacks?
      (@doc["paths"] || {}).values.any? do |item|
        next false unless item.is_a?(Hash)

        HTTP_VERBS.any? { |verb| item.dig(verb, "callbacks").is_a?(Hash) }
      end
    end

    def webhook_events
      @webhook_events ||= begin
        events = []
        events.concat(events_from_webhooks_block)
        events.concat(events_from_callbacks)
        events.concat(events_from_path_webhooks)
        events.concat(events_from_schema_enum)
        events.uniq(&:type)
      end
    end

    def events_from_webhooks_block
      webhooks = @doc["webhooks"]
      return [] unless webhooks.is_a?(Hash)

      webhooks.filter_map do |name, item|
        operation = webhook_operation(item)
        next unless operation

        schema = content_schema(operation["requestBody"] || {}) || content_schema(operation.dig("responses", "200") || {})
        example = content_example(operation["requestBody"] || {}) || (schema && synthesize_example(schema))
        type = example.is_a?(Hash) && (example["type"] || example[:type])
        type ||= event_type_from_name(name)
        WebhookEvent.new(
          name: name.to_s,
          type: type.to_s,
          description: operation["description"] || operation["summary"].to_s,
          example: example
        )
      end
    end

    def events_from_callbacks
      found = []
      (@doc["paths"] || {}).each_value do |item|
        next unless item.is_a?(Hash)

        HTTP_VERBS.each do |verb|
          callbacks = item.dig(verb, "callbacks")
          next unless callbacks.is_a?(Hash)

          callbacks.each do |name, callback|
            next unless callback.is_a?(Hash)

            callback.each_value do |path_item|
              operation = webhook_operation(path_item)
              next unless operation

              schema = content_schema(operation["requestBody"] || {})
              example = content_example(operation["requestBody"] || {}) || (schema && synthesize_example(schema))
              type = example.is_a?(Hash) && example["type"]
              type ||= event_type_from_name(name)
              found << WebhookEvent.new(name: name.to_s, type: type.to_s, description: operation["summary"].to_s, example: example)
            end
          end
        end
      end
      found
    end

    def events_from_schema_enum
      event_schema = (@doc.dig("components", "schemas") || {}).find do |name, _|
        name.to_s.match?(/webhook|event/i)
      end
      return [] unless event_schema

      schema = flatten_schema(event_schema.last)
      enum = schema.dig("properties", "event", "enum") || schema.dig("properties", "type", "enum")
      return [] unless enum.is_a?(Array)

      example = schema["example"]
      enum.map do |type|
        key = schema.dig("properties", "event") ? "event" : "type"
        ev_example = example.is_a?(Hash) ? example.merge(key => type) : { key => type }
        WebhookEvent.new(name: type, type: type, description: "", example: ev_example)
      end
    end

    def events_from_path_webhooks
      found = []
      (@doc["paths"] || {}).each do |path, item|
        next unless path.to_s.match?(/webhook/i)
        next unless item.is_a?(Hash)

        HTTP_VERBS.each do |verb|
          operation = item[verb]
          next unless operation.is_a?(Hash)

          named_examples_from(operation["requestBody"]).each do |name, value|
            type = value.is_a?(Hash) && (value["event"] || value["type"])
            type ||= event_type_from_name(name)
            found << WebhookEvent.new(name: name.to_s, type: type.to_s, description: operation["summary"].to_s, example: value)
          end
        end
      end
      found
    end

    def webhook_operation(item)
      return item if item.is_a?(Hash) && HTTP_VERBS.any? { |v| item[v] }.nil? && item["requestBody"]
      return nil unless item.is_a?(Hash)

      HTTP_VERBS.each do |verb|
        return item[verb] if item[verb].is_a?(Hash)
      end
      nil
    end

    def event_type_from_name(name)
      slug = Inflector.underscore(name.to_s).tr("_", ".")
      slug.sub(/\Awebhook\./, "")
    end

    def webhook_header
      blob = @doc.to_s
      match = blob.match(/X-[A-Za-z0-9-]*Signature[A-Za-z0-9-]*/i)
      match && match[0]
    end

    def webhook_algorithm
      blob = @doc.to_s
      return "SHA256" if blob.match?(/HMAC-SHA-?256/i)
      return "SHA512" if blob.match?(/HMAC-SHA-?512/i)
      return "SHA1" if blob.match?(/HMAC-SHA-?1\b/i)

      nil
    end

    def webhook_format
      blob = @doc.to_s
      return :stripe_style if blob.match?(/t=<unix/i) || blob.match?(/v1=<hex/i) || blob.match?(/"t=.*,v1=/i)

      :raw_hex
    end
  end

  class Analysis
    attr_reader :raw, :gem_name, :module_name, :provider_slug, :title, :version, :description
    attr_reader :sandbox_url, :live_url, :operations, :schemas, :security_schemes, :default_security
    attr_reader :has_webhooks, :webhook_events, :webhook_header, :webhook_algorithm, :webhook_format
    attr_reader :has_idempotency, :idempotency_header, :preferred_auth

    def initialize(attrs)
      attrs.each { |key, value| instance_variable_set(:"@#{key}", value) }
    end

    def major_resources
      names = operations.map(&:resource).uniq
      preferred = names.select { |name| PAYMENT_HINT.match?(name) }
      (preferred + names).uniq
    end

    def operations_for(resource)
      operations.select { |op| op.resource == resource }
    end

    def schema_named(*candidates)
      lowered = candidates.map { |c| Inflector.camelize(c.to_s).downcase }
      schemas.find { |schema| lowered.include?(schema.const_name.downcase) }
    end

    def payment_schema
      schema_named("Payment", "Charge", "Intent")
    end

    def refund_schema
      schema_named("Refund")
    end

    def customer_schema
      schema_named("Customer")
    end

    def error_schema
      schema_named("Error", "APIError", "ErrorResponse")
    end

    def webhook_schema
      schema_named("WebhookEvent", "Event", "Webhook")
    end

    def auth_kind
      preferred_auth[:kind]
    end

    def auth_header
      preferred_auth[:header]
    end

    def auth_scheme_key
      preferred_auth[:key].to_s
    end

    def sandbox_origin
      split_url(sandbox_url).fetch(:origin)
    end

    def sandbox_prefix
      split_url(sandbox_url).fetch(:prefix)
    end

    def live_origin
      split_url(live_url).fetch(:origin)
    end

    def live_prefix
      split_url(live_url).fetch(:prefix)
    end

    def expanded_path(operation, overrides = {})
      path = operation.path.dup
      operation.path_params.each do |param|
        value = overrides[param.ruby_name] || overrides[param.name] || param.example || "id"
        path = path.gsub("{#{param.name}}", URI.encode_www_form_component(value.to_s))
      end
      "#{sandbox_prefix}#{path}"
    end

    def absolute_url(operation, overrides = {})
      "#{sandbox_origin}#{expanded_path(operation, overrides)}"
    end

    PAYMENT_HINT = /payment|charge|refund|customer|invoice|payout|intent/i

    private

    def split_url(url)
      uri = URI.parse(url)
      origin = "#{uri.scheme}://#{uri.host}"
      origin += ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)
      prefix = uri.path.to_s.sub(%r{/\z}, "")
      { origin: origin, prefix: prefix }
    rescue URI::InvalidURIError
      { origin: url, prefix: "" }
    end
  end
end
