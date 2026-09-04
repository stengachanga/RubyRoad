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

    attr_reader :analysis, :warnings, :parse_notes, :todos, :overrides

    def initialize(analysis, overrides: Overrides.empty)
      @analysis = analysis
      @overrides = overrides || Overrides.empty
      @warnings = []
      @parse_notes = []
      @todos = []
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
      return @amount_scale if defined?(@amount_scale)

      @amount_scale = resolve_amount_scale
    end

    def signature_encoding
      overrides.signature_encoding || "hex"
    end

    def signature_encoding_pinned?
      !overrides.signature_encoding.nil?
    end

    def hmac_raw_body?
      return false if overrides.signature_payload.to_s.match?(/timestamp/i)
      return true if overrides.signature_payload.to_s.match?(/raw/i)

      analysis.webhook_format != :stripe_style
    end

    def callback_algorithm
      overrides.signature_algorithm || analysis.webhook_algorithm
    end

    def callback_actionable?
      inbound_webhook_op && analysis.webhook_header && callback_algorithm
    end

    def payout_methods
      type = recipient_properties.find { |prop| prop[:ruby_name] == "type" }
      Array(type&.[](:enum)).map(&:to_s)
    end

    def required_if_rules
      pinned = overrides.required_if
      return pinned.map { |rule| normalize_required_if(rule) } unless pinned.empty?

      description_required_if
    end

    def required_if_pinned?
      !overrides.required_if.empty?
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
          enum: prop.is_a?(Hash) ? Array(prop["enum"]) : [],
          description: prop.is_a?(Hash) ? prop["description"].to_s : ""
        }
      end
    end

    def phone_pattern
      recipient_properties.find { |prop| prop[:ruby_name] == "phone" }&.[](:pattern)
    end

    def status_map
      enums = status_enum
      if enums.empty?
        note("status map: no enum on the payout schema; using keyword STATUS_MAP.")
        return SPACE_STATUS.dup
      end

      enums.each_with_object({}) do |status, acc|
        mapped = SPACE_STATUS[status.to_s]
        unless mapped
          note("status #{status.inspect}: no keyword match; mapped to in_progress.")
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
      return "described, not bound (no clear inbound HMAC path)" unless callback_actionable?

      "#{analysis.webhook_header} (HMAC-#{callback_algorithm})"
    end

    def collect_warnings
      classify! if create_op.nil? && @warnings.empty? && @parse_notes.empty?
      if create_op.nil?
        @warnings << "No create payout operation found (POST collection). create_request will be a stub."
      elsif payout_score(create_op) < 40
        @warnings << "Bound create #{create_op.http_method.upcase} #{create_op.path} " \
                     "does not look like a payout API (no /payouts signal). Confirm before embedding."
      end
      if status_op.nil?
        @warnings << "No GET-by-id status operation found. fetch_status will be a stub."
      end
      unmapped_ops = unmapped_operations
      unless unmapped_ops.empty?
        listed = unmapped_ops.map { |op| "#{op.http_method.upcase} #{op.path}" }.join(", ")
        @warnings << "Unmapped spec element: #{listed} — not bound to provider-service methods; skipped."
      end
      if analysis.auth_kind == :unsupported
        @warnings << "OAuth2/OIDC securitySchemes are not generated; fill auth_headers by hand."
      end
      analysis.security_schemes.each do |scheme|
        if %w[oauth2 openIdConnect].include?(scheme.type)
          @warnings << "Unsupported security scheme #{scheme.key} (#{scheme.type})."
        end
      end
      amount_scale
      status_map
      required_if_rules
      unless required_if_pinned?
        description_required_if.each do |rule|
          todo("required_if #{rule['field']} when type=#{rule.dig('when', 'type')} is only in description, not oneOf. Pin it with required_if in overrides.")
        end
      end
      if amount_from_description? && overrides.amount_unit.nil? && overrides.amount_scale.nil?
        todo("amount_unit taken from description, not schema. Pin amount_unit (minor|major) in overrides.")
      end
      if callback_actionable? && !signature_encoding_pinned?
        todo("HMAC encoding (hex vs base64) is not in the spec structure. Using hex as best-effort; pin signature_encoding in overrides.")
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
      @webhook_op = pick_closest(ops.select { |op| webhook?(op) }, role: "process_callback")
      @cancel_op = pick_closest(ops.select { |op| cancel?(op) }, role: "cancel_request")
      @balance_op = pick_closest(ops.select { |op| balance?(op) }, role: "get_balance")
      @status_op = pick_closest(ops.select { |op| status?(op) }, role: "fetch_status")
      @create_op = pick_closest(ops.select { |op| create_candidate?(op) }, role: "create_request")
      unless callback_actionable?
        note("process_callback: spec has no clear inbound path and HMAC scheme; method is a no-op.")
      end
    end

    def classified_ops
      [create_op, status_op, cancel_op, webhook_op, balance_op].compact.uniq
    end

    def unmapped_operations
      analysis.operations.reject { |op| classified_ops.include?(op) || webhook?(op) }
    end

    def synthetic_webhook_op
      event = analysis.webhook_events.first
      examples = analysis.webhook_events.each_with_object({}) do |ev, acc|
        acc[ev.type] = ev.example if ev.example
      end
      Operation.new(
        operation_id: "webhook",
        method_name: "process_callback",
        http_method: "post",
        path: "/webhooks",
        summary: event&.description.to_s,
        description: "Declared in OpenAPI webhooks: (no path).",
        tags: ["Webhooks"],
        resource: "webhooks",
        path_params: [],
        query_params: [],
        header_params: [],
        body_properties: [],
        has_request_body: true,
        request_example: event&.example,
        success_status: 200,
        success_schema_name: nil,
        success_const: nil,
        success_example: nil,
        success_is_list: false,
        success_item_const: nil,
        error_status: 400,
        error_example: nil,
        has_idempotency: false,
        idempotency_header: analysis.idempotency_header,
        fixture_name: "webhook",
        request_examples: examples,
        response_examples: {}
      )
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

    def create_candidate?(op)
      return false if webhook?(op) || cancel?(op) || balance?(op)

      (op.http_method == "post" && op.path_params.empty?) ||
        op.method_name.match?(/create_(payout|payment|transfer|withdrawal|disbursement)/)
    end

    def create?(op)
      create_candidate?(op)
    end

    def pick_closest(candidates, role:)
      return nil if candidates.empty?

      ranked = candidates.sort_by { |op| [-payout_score(op), op.path] }
      best = ranked.first
      if ranked.size > 1
        others = ranked.drop(1).map { |op| "#{op.http_method.upcase} #{op.path}" }.join(", ")
        note("#{role}: bound #{best.http_method.upcase} #{best.path} as closest payout match; also in spec: #{others}.")
      end
      best
    end

    def payout_score(op)
      blob = "#{op.path} #{op.operation_id} #{op.method_name} #{op.resource} #{op.summary} #{op.description}"
      score = 0
      score += 100 if blob.match?(/payout/i)
      score += 80 if blob.match?(/withdraw|disburse/i)
      score += 50 if blob.match?(/\btransfer\b/i)
      score += 20 if blob.match?(/\bpayment/i)
      score += 40 if op.path.match?(%r{/payouts(/|\z)}i)
      score -= 80 if blob.match?(/deposit|charge|acquir|customer|invoice|refund/i)
      score -= 40 if blob.match?(/health|ping|ready/i)
      score
    end

    def inbound_webhook_op
      webhook_op
    end

    def note(message)
      @parse_notes << message unless @parse_notes.include?(message)
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
          "message" => "Request failed validation"
        }
      }
    end

    def default_callback(kind)
      {
        "event" => "payout.#{kind}",
        "payout_id" => "payout_example",
        "external_id" => "operation_example",
        "status" => kind
      }
    end

    def amount_currency_enum
      create_op&.body_properties&.find { |prop| prop.ruby_name == "currency" }&.enum || []
    end

    def resolve_amount_scale
      return overrides.amount_scale if overrides.amount_scale
      return 100 if overrides.amount_unit == "minor"
      return 1 if overrides.amount_unit == "major"

      blob = amount_unit_blob
      return 100 if blob.match?(/kopeck|копе|cent\b|cents|minor/i)
      return 1 if blob.match?(/major unit/i)

      min = amount_minimum_minor
      if min && min >= 1000
        note("amount scale: spec has no unit; inferred 100 from minimum #{min}.")
        return 100
      end

      note("amount scale: spec has no unit; using 100 (closest minor-unit convention).")
      100
    end

    def amount_unit_blob
      "#{create_op&.description} #{amount_property&.description} #{amount_property&.schema.inspect}"
    end

    def amount_from_description?
      return false if overrides.amount_unit || overrides.amount_scale

      amount_unit_blob.match?(/kopeck|копе|cent\b|cents|minor/i) ||
        amount_unit_blob.match?(/major unit/i)
    end

    def description_required_if
      recipient_properties.filter_map do |prop|
        desc = prop[:description].to_s
        match = desc.match(/обязателен для type\s*=\s*([A-Za-z0-9_]+)/i) ||
                desc.match(/required for type\s*=\s*([A-Za-z0-9_]+)/i)
        next unless match

        normalize_required_if("field" => prop[:name], "when" => { "type" => match[1] })
      end
    end

    def normalize_required_if(rule)
      field = (rule["field"] || rule[:field]).to_s
      when_h = rule["when"] || rule[:when] || {}
      type = (when_h["type"] || when_h[:type]).to_s
      { "field" => field, "when" => { "type" => type } }
    end

    def todo(message)
      @todos << message unless @todos.include?(message)
      @warnings << "TODO: #{message}" unless @warnings.include?("TODO: #{message}")
    end
  end

  class Integrator
    DEFAULT_SPEC = "examples/provider_api.yaml"
    DEFAULT_OUT = "output"

    def self.generate(spec:, provider:, out: nil, lang: "ruby", copy_rails: false, overrides: nil, force: nil)
      new(
        spec: spec,
        provider: provider,
        out: out,
        lang: lang,
        copy_rails: copy_rails,
        overrides: overrides,
        force: force
      ).generate
    end

    def initialize(spec:, provider:, out: nil, lang: "ruby", copy_rails: false, overrides: nil, force: nil)
      @source = spec
      @provider = provider
      @out = out
      @lang = lang
      @copy_rails = copy_rails
      @overrides = overrides
      @force = force
    end

    def generate
      warnings = []
      unless @lang.to_s.strip.empty? || @lang.to_s.downcase == "ruby"
        warnings << "--lang #{@lang} is not supported; generating Ruby (Space Payments contract)."
      end

      document = SpecLoader.load(@source)
      analysis = Analyzer.new(document, name: @provider).analyze
      profile = PayoutProfile.new(analysis, overrides: Overrides.discover(@source, explicit: @overrides))
      warnings.concat(profile.collect_warnings)

      dest = File.expand_path(@out || DEFAULT_OUT)
      FileUtils.mkdir_p(dest)

      context = TemplateContext.new(analysis)
      context.profile = profile

      service_name = "#{profile.file_stem}.rb"
      service_path = File.join(dest, service_name)
      assert_overwrite_allowed!(service_path)

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

    def assert_overwrite_allowed!(service_path)
      return unless File.file?(service_path)
      return if force_overwrite?

      raise Error,
            "Refusing to overwrite #{service_path} without --force " \
            "(default ./output may overwrite; other --out paths require --force)."
    end

    def force_overwrite?
      return true if @force == true
      return false if @force == false

      default_out_dir?
    end

    def default_out_dir?
      requested = File.expand_path(@out || DEFAULT_OUT)
      default = File.expand_path(DEFAULT_OUT)
      requested == default
    end
  end

  class TemplateContext
    attr_accessor :profile

    def initialize(analysis)
      @analysis = analysis
    end

    def analysis
      @analysis
    end

    def a
      @analysis
    end

    def header_comment
      "# This file was generated by RubyRoad #{VERSION} from an OpenAPI specification.\n" \
        "# Regenerating will overwrite local changes."
    end

    def get_binding
      binding
    end
  end
end
