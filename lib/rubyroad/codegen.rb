# frozen_string_literal: true

require "json"

module Rubyroad
  # Builds Ruby and Markdown snippets that ERB templates interpolate.
  class Codegen
    def initialize(analysis)
      @a = analysis
    end

    def operation_methods(indent: 4)
      pad = " " * indent
      @a.operations.map { |op| indent_block(render_operation(op), pad) }.join("\n\n")
    end

    def model_classes(indent: 4)
      pad = " " * indent
      blocks = []
      @a.schemas.each do |schema|
        next if schema.const_name.match?(/Error$/) && schema.properties.empty?

        blocks << render_model(schema)
      end
      ensure_core_models(blocks)
      blocks.map { |block| indent_block(block, pad) }.join("\n\n")
    end

    def docs_operations
      @a.operations.map { |op| render_api_doc(op) }.join("\n")
    end

    def mermaid_sequence
      return "" unless @a.has_webhooks

      events = @a.webhook_events.map(&:type).uniq
      success = events.find { |e| e.include?("succeed") } || events.first || "payment.succeeded"
      <<~MERMAID
        ```mermaid
        sequenceDiagram
          participant Merchant
          participant #{@a.module_name}
          participant Provider as #{escape_mermaid(@a.title)}
          participant Webhook as Merchant webhook
          Merchant->>#{@a.module_name}: create_payment(...)
          #{@a.module_name}->>Provider: POST /payments (+ Idempotency-Key)
          Provider-->>#{@a.module_name}: 201 Payment
          #{@a.module_name}-->>Merchant: Payment model
          Provider->>Webhook: #{success} (HMAC-SHA256)
          Webhook->>#{@a.module_name}: Webhooks.verify! / handle
          #{@a.module_name}-->>Webhook: dispatch by event.type
        ```
      MERMAID
    end

    def example_kwargs(operation, for_error: false)
      bits = []
      operation.path_params.each do |param|
        bits << "#{param.ruby_name}: #{ruby_literal(example_path_value(operation, param))}"
      end
      operation.query_params.select(&:required).each do |param|
        bits << "#{param.ruby_name}: #{ruby_literal(param.example)}"
      end
      if operation.has_request_body
        example = operation.request_example
        example = {} unless example.is_a?(Hash)
        operation.body_properties.each do |prop|
          next unless prop.required || example.key?(prop.name) || example.key?(prop.name.to_sym)

          value = hash_value(example, prop.name)
          value = prop.example if value.nil?
          value = synthesized_prop_value(prop) if value.nil?
          next if value.nil? && !prop.required

          bits << "#{prop.ruby_name}: #{ruby_literal(coerce_money_value(prop, value))}"
        end
      end
      if operation.has_idempotency && !for_error
        bits << "idempotency_key: \"req_demo_001\""
      end
      bits.join(", ")
    end

    def ruby_literal(value)
      case value
      when nil then "nil"
      when true then "true"
      when false then "false"
      when Integer then value.to_s
      when Float
        # Never emit floats for generated payment code.
        Integer(value).to_s
      when String then value.inspect
      when Symbol then value.to_s.inspect
      when Hash
        inner = value.map { |k, v| "#{hash_key(k)}: #{ruby_literal(v)}" }.join(", ")
        "{ #{inner} }"
      when Array
        "[#{value.map { |v| ruby_literal(v) }.join(', ')}]"
      else
        value.to_s.inspect
      end
    end

    def first_payment_example
      op = @a.operations.find { |o| o.method_name.include?("payment") && o.http_method == "post" } ||
           @a.operations.find { |o| o.http_method == "post" }
      return "# client.create_payment(amount: 2500, currency: \"USD\")" unless op

      "client.#{op.method_name}(#{example_kwargs(op)})"
    end

    def webmock_regex(operation)
      prefix = Regexp.escape(@a.sandbox_prefix)
      path = operation.path.split("/").map do |segment|
        segment.match?(/\A\{.*\}\z/) ? "[^/?]+" : Regexp.escape(segment)
      end.join("/")
      "#{prefix}#{path}(?:\\?.*)?\\z"
    end

    def grouped_operations
      @a.operations.group_by(&:resource)
    end

    def assertion_id(operation)
      example = operation.success_example
      return nil unless example.is_a?(Hash)

      example["id"] || example[:id]
    end

    private

    def render_operation(op)
      args = method_args(op)
      sig = args.empty? ? op.method_name : "#{op.method_name}(#{args})"
      lines = []
      lines << "def #{sig}"
      lines.concat(operation_body(op).map { |line| "  #{line}" })
      lines << "end"
      comment = op.summary.empty? ? "#{op.http_method.upcase} #{op.path}" : op.summary
      "# #{comment}\n#\n# @return [#{return_type(op)}]\ndef_placeholder"
        .sub("def_placeholder", lines.join("\n"))
    end

    def method_args(op)
      required = []
      optional = []
      op.path_params.each { |p| required << "#{p.ruby_name}:" }
      op.body_properties.select(&:required).each { |p| required << "#{p.ruby_name}:" }
      op.query_params.each do |p|
        if p.required
          required << "#{p.ruby_name}:"
        else
          optional << "#{p.ruby_name}: nil"
        end
      end
      op.body_properties.reject(&:required).each { |p| optional << "#{p.ruby_name}: nil" }
      op.header_params.each do |p|
        optional << "#{p.ruby_name}: nil" unless p.name.match?(/authorization|api[-_]?key/i)
      end
      optional << "idempotency_key: nil" if op.has_idempotency
      (required + optional).join(", ")
    end

    def operation_body(op)
      lines = []
      unless op.path_params.empty?
        lines << "path = expand_path(#{op.path.inspect}, { #{op.path_params.map { |p| "#{p.ruby_name}: #{p.ruby_name}" }.join(', ')} })"
      else
        lines << "path = #{op.path.inspect}"
      end

      if op.has_request_body
        lines << "body = {}"
        op.body_properties.each do |prop|
          assign = body_assign(prop, op)
          if prop.required
            lines << assign
          else
            lines << "unless #{prop.ruby_name}.nil?"
            lines << "  #{assign}"
            lines << "end"
          end
        end
      end

      query_params = op.query_params
      unless query_params.empty?
        lines << "query = {}"
        query_params.each do |param|
          if param.required
            lines << "query[:#{param.ruby_name}] = #{param.ruby_name}"
          else
            lines << "query[:#{param.ruby_name}] = #{param.ruby_name} unless #{param.ruby_name}.nil?"
          end
        end
      end

      extra_headers = op.header_params.reject { |p| p.name.match?(/authorization|api[-_]?key/i) }
      if op.has_idempotency || extra_headers.any?
        lines << "headers = {}"
        extra_headers.each do |param|
          lines << "headers[#{param.name.inspect}] = #{param.ruby_name} unless #{param.ruby_name}.nil?"
        end
        if op.has_idempotency
          header = op.idempotency_header || "Idempotency-Key"
          lines << "headers[#{header.inspect}] = idempotency_key unless idempotency_key.nil?"
        end
      end

      call = "request(:#{op.http_method}, path"
      call += ", body: body" if op.has_request_body
      call += ", query: query" unless query_params.empty?
      call += ", headers: headers" if op.has_idempotency || extra_headers.any?
      call += ")"
      lines << "payload = #{call}"
      lines << wrap_response(op)
      lines
    end

    def body_assign(prop, op)
      key = "body[:#{prop.ruby_name}]"
      if prop.money || prop.ruby_name == "amount"
        "#{key} = normalize_money_amount(#{prop.ruby_name})"
      elsif prop.ruby_name == "currency"
        if op.body_properties.any? { |item| item.ruby_name == "amount" }
          "#{key} = normalize_currency(#{prop.ruby_name}, amount)"
        else
          "#{key} = normalize_currency(#{prop.ruby_name})"
        end
      else
        "#{key} = #{prop.ruby_name}"
      end
    end

    def wrap_response(op)
      const = op.success_const
      if op.success_is_list
        item = op.success_item_const || "Resource"
        "Models::Collection.new(payload, item_class: Models::#{item})"
      elsif const && !const.empty?
        if op.success_status == 204
          "true"
        else
          "Models::#{const}.new(payload)"
        end
      else
        "Models::Resource.new(payload)"
      end
    end

    def return_type(op)
      if op.success_is_list
        "Models::Collection<Models::#{op.success_item_const || 'Resource'}>"
      elsif op.success_const
        "Models::#{op.success_const}"
      else
        "Models::Resource"
      end
    end

    def render_model(schema)
      fields = schema.properties.map(&:ruby_name)
      extra = []
      if schema.money_like
        extra << <<~RUBY.chomp
          def money
            raw_amount = self[:amount] || self[:cents] || self[:amount_cents]
            raw_currency = self[:currency] || self[:currency_code]
            return nil if raw_amount.nil? || raw_currency.nil?
            raise ArgumentError, "amount must be integer minor units, never Float" if raw_amount.is_a?(Float)

            Money.new(cents: Integer(raw_amount), currency: raw_currency.to_s)
          end
        RUBY
      end
      if schema.properties.any? { |p| p.ruby_name == "status" }
        extra << <<~RUBY.chomp
          def succeeded?
            status.to_s == "succeeded"
          end

          def failed?
            status.to_s == "failed"
          end
        RUBY
      end

      field_list = fields.map { |f| ":#{f}" }.join(", ")
      body = []
      body << "class #{schema.const_name} < Resource"
      body << (fields.empty? ? "  # Schema declares no explicit properties; raw accessors still work via #[]" : "  field #{field_list}")
      extra.each do |chunk|
        body << chunk.gsub(/^/, "  ")
      end
      body << "end"
      comment = schema.description.empty? ? "OpenAPI schema #{schema.name}" : schema.description.lines.first.to_s.strip
      "# #{comment}\n#{body.join("\n")}"
    end

    def ensure_core_models(blocks)
      have = @a.schemas.map { |s| s.const_name.downcase }
      {
        "Payment" => %i[id amount currency status customer_id description metadata created_at],
        "Refund" => %i[id payment_id amount currency status reason created_at],
        "Customer" => %i[id email name metadata created_at],
        "WebhookEvent" => %i[id type created_at data],
        "ErrorDetail" => %i[type code message param doc_url]
      }.each do |name, fields|
        next if have.include?(name.downcase) || have.include?(name.delete_suffix("Detail").downcase)

        fake = SchemaModel.new(
          name: name,
          const_name: name,
          description: "#{name} (inferred — fill in provider-specific fields)",
          properties: fields.map { |f| Property.new(name: f.to_s, ruby_name: f.to_s, type: "string", format: "", required: false, description: "", example: nil, enum: [], money: f == :amount, ref_name: nil, schema: {}) },
          money_like: fields.include?(:amount) && fields.include?(:currency),
          list: false,
          item_const: nil,
          example: nil,
          raw: {}
        )
        blocks << render_model(fake)
      end
    end

    def render_api_doc(op)
      params = []
      op.path_params.each { |p| params << doc_param(p, source: "path") }
      op.query_params.each { |p| params << doc_param(p, source: "query") }
      op.body_properties.each { |p| params << doc_prop(p) }
      params << "- `idempotency_key` (header, optional) — replay-safe writes" if op.has_idempotency

      request = op.request_example ? pretty_json(op.request_example) : "_(no request body)_"
      response = op.success_example ? pretty_json(op.success_example) : "_(empty)_"
      error = op.error_example ? pretty_json(op.error_example) : "_(see docs/AUTH.md)_"

      <<~MD
        ## `#{@a.module_name}::Client##{op.method_name}`

        `#{op.http_method.upcase} #{op.path}`#{op.operation_id.empty? ? '' : " — operationId: `#{op.operation_id}`"}

        #{op.summary.empty? ? op.description : op.summary}

        **Signature**

        ```ruby
        client.#{op.method_name}(#{example_kwargs(op)})
        ```

        **Parameters**

        #{params.empty? ? '_None._' : params.join("\n")}

        **Example request**

        ```json
        #{request}
        ```

        **Example response** (`#{op.success_status}`)

        ```json
        #{response}
        ```

        **Example error** (`#{op.error_status}`)

        ```json
        #{error}
        ```

      MD
    end

    def doc_param(param, source:)
      req = param.required ? "required" : "optional"
      extra = param.description.empty? ? "" : " — #{param.description}"
      "- `#{param.ruby_name}` (#{source}, #{req}, #{param.type.empty? ? 'string' : param.type})#{extra}"
    end

    def doc_prop(prop)
      req = prop.required ? "required" : "optional"
      type = prop.money ? "integer minor units" : (prop.type.empty? ? "any" : prop.type)
      extra = prop.description.empty? ? "" : " — #{prop.description}"
      extra += " (money: integer cents, never Float)" if prop.money
      "- `#{prop.ruby_name}` (body, #{req}, #{type})#{extra}"
    end

    def pretty_json(value)
      JSON.pretty_generate(value)
    rescue JSON::GeneratorError
      value.inspect
    end

    def example_path_value(operation, param)
      example = operation.success_example
      if example.is_a?(Hash)
        return example[param.name] if example[param.name]
        return example[param.ruby_name] if example[param.ruby_name]
        return example["payment_id"] if param.ruby_name.include?("payment") && example["payment_id"]
        return example["customer_id"] if param.ruby_name.include?("customer") && example["customer_id"]
        return example["id"] if param.ruby_name.end_with?("id") && example["id"]
      end
      param.example
    end

    def hash_value(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s] || hash[key.to_sym]
    end

    def synthesized_prop_value(prop)
      return 2500 if prop.money || prop.ruby_name == "amount"
      return "USD" if prop.ruby_name.include?("currency")
      return "cus_test_123" if prop.ruby_name.include?("customer")
      return false if prop.type == "boolean"

      prop.example || "example"
    end

    def coerce_money_value(prop, value)
      if (prop.money || prop.ruby_name == "amount") && value.is_a?(Float)
        return Integer(value)
      end

      value
    end

    def hash_key(key)
      ident = Inflector.ruby_ident(key)
      ident
    end

    def indent_block(source, pad)
      source.to_s.gsub(/^(?!$)/, pad)
    end

    def escape_mermaid(text)
      text.to_s.gsub(/[^A-Za-z0-9 _-]/, "").squeeze(" ").strip
    end
  end
end
