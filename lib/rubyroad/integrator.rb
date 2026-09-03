# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"

module Rubyroad
  # Maps OpenAPI operations onto the Space Payments Provider::BaseService contract.
  class PayoutProfile
    SPACE_STATUS = {
      "pending" => "in_progress",
      "processing" => "in_progress",
      "in_progress" => "in_progress",
      "queued" => "in_progress",
      "new" => "in_progress",
      "completed" => "approved",
      "succeeded" => "approved",
      "success" => "approved",
      "paid" => "approved",
      "approved" => "approved",
      "failed" => "rejected",
      "cancelled" => "rejected",
      "canceled" => "rejected",
      "rejected" => "rejected",
      "declined" => "rejected",
      "error" => "rejected"
    }.freeze

    ERROR_ACTIONS = {
      400 => "reject the operation (invalid request)",
      401 => "alert ops and block the provider (bad API key)",
      402 => "retry later (insufficient provider balance)",
      404 => "reject — resource not found",
      409 => "treat as success if this is an idempotent replay; otherwise reject",
      422 => "reject the operation (validation error)",
      429 => "backoff using Retry-After, then retry",
      500 => "retry and alert ops (provider internal error)"
    }.freeze

    attr_reader :analysis, :warnings

    def initialize(analysis)
      @analysis = analysis
      @warnings = []
      classify!
    end

    attr_reader :create_op, :status_op, :cancel_op, :webhook_op, :balance_op

    def service_class
      "Provider::#{analysis.module_name}Service"
    end

    def file_stem
      "#{analysis.gem_name}_service"
    end

    def env_prefix
      analysis.module_name.upcase
    end

    def currency
      enum = amount_currency_enum
      enum.first || "RUB"
    end

    def amount_scale
      blob = "#{create_op&.description} #{amount_property&.description} #{amount_property&.schema.inspect}"
      return 100 if blob.match?(/kopeck|копе|cent\b|cents|minor/i)
      return 1 if blob.match?(/major unit/i)

      min = amount_minimum
      return 100 if min && min >= 1000

      @warnings << "Amount scale is assumed to be 100 (minor units). Confirm against the spec."
      100
    end

    def amount_minimum_minor
      amount_property&.schema&.[]("minimum")
    end

    def amount_minimum_major
      min = amount_minimum_minor
      return nil unless min

      min.to_f / amount_scale
    end

    def amount_property
      create_op&.body_properties&.find { |prop| prop.ruby_name == "amount" }
    end

    def recipient_properties
      recipient = create_op&.body_properties&.find { |prop| prop.ruby_name == "recipient" }
      return [] unless recipient

      schema = recipient.schema || {}
      required = Array(schema["required"])
      (schema["properties"] || {}).map do |name, prop|
        {
          name: name,
          ruby_name: Inflector.ruby_ident(name),
          required: required.include?(name),
          pattern: prop.is_a?(Hash) ? prop["pattern"] : nil,
          enum: prop.is_a?(Hash) ? Array(prop["enum"]) : []
        }
      end
    end

    def phone_pattern
      recipient_properties.find { |prop| prop[:ruby_name] == "phone" }&.[](:pattern)
    end

    def status_map
      enums = status_enum
      if enums.empty?
        @warnings << "No status enum found on the payout schema; using a generic STATUS_MAP."
        return SPACE_STATUS.dup
      end

      enums.each_with_object({}) do |status, acc|
        mapped = SPACE_STATUS[status.to_s]
        unless mapped
          @warnings << "Unmapped provider status #{status.inspect}; defaulting to in_progress."
          mapped = "in_progress"
        end
        acc[status.to_s] = mapped
      end
    end

    def status_enum
      schema = analysis.schema_named("Payout", "PayoutResponse", "Payment", "Transfer")
      from_schema = schema&.properties&.find { |prop| prop.ruby_name == "status" }&.enum
      return from_schema if from_schema && !from_schema.empty?

      example = (status_op&.success_example || create_op&.success_example)
      return [] unless example.is_a?(Hash)

      []
    end

    def webhook_events
      analysis.webhook_events
    end

    def hmac_raw_body?
      analysis.webhook_format != :stripe_style
    end

    def endpoint_list
      analysis.operations.map { |op| "#{op.http_method.upcase} #{op.path}" }
    end

    def auth_summary
      key = analysis.auth_scheme_key
      key = "ApiKeyAuth" if key.empty? && analysis.auth_kind == :api_key
      case analysis.auth_kind
      when :api_key
        "#{key} (header: #{analysis.auth_header})"
      when :basic
        "#{key} (HTTP Basic)"
      when :unsupported
        "#{key} (unsupported #{analysis.preferred_auth[:type]}; generated Bearer placeholder)"
      else
        "#{key.empty? ? 'bearerAuth' : key} (header: Authorization Bearer)"
      end
    end

    def webhook_summary
      return "not described in spec" unless analysis.has_webhooks

      algo = analysis.webhook_algorithm
      header = analysis.webhook_header
      how = hmac_raw_body? ? "HMAC-#{algo} of raw body" : "HMAC-#{algo} timestamped (t=,v1=)"
      "#{header} (#{how})"
    end

    def collect_warnings
      classify! if create_op.nil? && @warnings.empty?
      if create_op.nil?
        @warnings << "No create payout/payment operation found (POST collection). create_request will be a stub."
      end
      if status_op.nil?
        @warnings << "No GET-by-id status operation found. fetch_status will be a stub."
      end
      if webhook_op.nil? && !analysis.has_webhooks
        @warnings << "No webhook path or callbacks found. process_callback cannot verify a signature."
      end
      if analysis.auth_kind == :unsupported
        @warnings << "OAuth2/OIDC securitySchemes are not generated; fill auth_headers by hand."
      end
      analysis.security_schemes.each do |scheme|
        if %w[oauth2 openIdConnect].include?(scheme.type)
          @warnings << "Unsupported security scheme #{scheme.key} (#{scheme.type})."
        end
      end
      @warnings.uniq
    end

    def fixtures
      create_req = create_op&.request_example || named_create_example
      {
        "create_request" => {
          "request" => create_req,
          "response_201" => response_example(create_op, %w[201 200]) || synthesized_payout,
          "response_422" => response_example(create_op, %w[422 400]) || default_validation_error
        },
        "fetch_status" => {
          "response_200" => status_op&.response_examples&.[]("200") || response_example(create_op, %w[201 200]) || synthesized_payout
        },
        "callback" => {
          "payload" => webhook_example(/complet|success|approved/i) || default_callback("completed"),
          "expected_operation_status" => "approved"
        },
        "callback_failed" => {
          "payload" => webhook_example(/fail|reject|cancel/i) || default_callback("failed"),
          "expected_operation_status" => "rejected"
        }
      }
    end

    private

    def classify!
      ops = analysis.operations
      @webhook_op = ops.find { |op| webhook?(op) }
      @cancel_op = ops.find { |op| cancel?(op) }
      @balance_op = ops.find { |op| balance?(op) }
      @status_op = ops.find { |op| status?(op) && op != @balance_op }
      @create_op = ops.find { |op| create?(op) }
    end

    def webhook?(op)
      op.path.match?(/webhook/i) || op.method_name.match?(/webhook|callback/i) ||
        op.header_params.any? { |p| p.name.match?(/signature/i) } && op.http_method == "post" && op.path_params.empty? && op.resource.to_s.match?(/webhook/i)
    end

    def cancel?(op)
      op.path.match?(/cancel/i) || op.method_name.match?(/cancel/i)
    end

    def balance?(op)
      op.path.match?(/balance/i) || op.method_name.match?(/balance/i)
    end

    def status?(op)
      op.http_method == "get" && op.path_params.any? && !webhook?(op) && !balance?(op)
    end

    def create?(op)
      return false if webhook?(op) || cancel?(op) || balance?(op)
      return true if op.http_method == "post" && op.path_params.empty?
      return true if op.method_name.match?(/create_(payout|payment|transfer|withdrawal|disbursement)/)

      false
    end

    def named_create_example
      examples = create_op&.request_examples
      return nil unless examples.is_a?(Hash) && examples.any?

      examples.values.first
    end

    def response_example(op, statuses)
      return nil unless op

      statuses.each do |status|
        value = op.response_examples&.[](status.to_s)
        return value if value
      end
      return op.success_example if statuses.map(&:to_i).include?(op.success_status.to_i)

      op.error_example if statuses.map(&:to_i).include?(op.error_status.to_i)
    end

    def webhook_example(pattern)
      named = webhook_op&.request_examples
      if named.is_a?(Hash)
        match = named.find { |name, _| name.match?(pattern) }
        return match.last if match
        named.each_value do |value|
          blob = value.to_s
          return value if blob.match?(pattern)
        end
      end
      analysis.webhook_events.find { |event| event.type.to_s.match?(pattern) }&.example
    end

    def synthesized_payout
      analysis.schema_named("PayoutResponse", "Payout", "Payment")&.example ||
        { "id" => "np_example", "status" => "pending", "amount" => 1500000 }
    end

    def default_validation_error
      {
        "error" => {
          "code" => "validation_error",
          "message" => "Amount must be at least 100000 kopecks"
        }
      }
    end

    def default_callback(kind)
      {
        "event" => "payout.#{kind}",
        "payout_id" => "np_7f3a9b2c",
        "external_id" => "op_abc123",
        "status" => kind
      }
    end

    def amount_currency_enum
      create_op&.body_properties&.find { |prop| prop.ruby_name == "currency" }&.enum || []
    end
  end

  class Integrator
    DEFAULT_SPEC = "examples/provider_api.yaml"

    def self.generate(spec:, provider:, out: nil, lang: "ruby", copy_rails: true)
      new(spec: spec, provider: provider, out: out, lang: lang, copy_rails: copy_rails).generate
    end

    def initialize(spec:, provider:, out: nil, lang: "ruby", copy_rails: true)
      @source = spec
      @provider = provider
      @out = out
      @lang = lang
      @copy_rails = copy_rails
    end

    def generate
      warnings = []
      unless @lang.to_s.strip.empty? || @lang.to_s.downcase == "ruby"
        warnings << "--lang #{@lang} is not supported; generating Ruby (Space Payments contract)."
      end

      document = SpecLoader.load(@source)
      analysis = Analyzer.new(document, name: @provider).analyze
      profile = PayoutProfile.new(analysis)
      warnings.concat(profile.collect_warnings)

      dest = File.expand_path(@out || "output")
      FileUtils.mkdir_p(dest)

      context = TemplateContext.new(analysis)
      context.profile = profile

      service_name = "#{profile.file_stem}.rb"
      service_body = render("service/service.rb.erb", context)
      write(dest, service_name, service_body)
      write(dest, "INTEGRATION.md", render("service/integration.md.erb", context))
      write(dest, "fixtures.json", JSON.pretty_generate(profile.fixtures) + "\n")

      rails_path = nil
      if @copy_rails
        rails_path = File.join(Rubyroad.root, "app/services/provider", service_name)
        FileUtils.mkdir_p(File.dirname(rails_path))
        File.write(rails_path, service_body)
      end

      {
        source: @source,
        out: dest,
        analysis: analysis,
        profile: profile,
        warnings: warnings,
        files: [
          File.join(dest, service_name),
          File.join(dest, "INTEGRATION.md"),
          File.join(dest, "fixtures.json")
        ],
        rails_path: rails_path
      }
    end

    private

    def render(template, context)
      path = File.join(Rubyroad.templates_path, template)
      raise Error, "Missing template #{template}" unless File.file?(path)

      erb = ERB.new(File.read(path), trim_mode: "-")
      erb.filename = path
      erb.result(context.get_binding)
    end

    def write(dest, relative, contents)
      path = File.join(dest, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end
  end
end
