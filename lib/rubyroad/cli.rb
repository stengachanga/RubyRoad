# frozen_string_literal: true

require "optparse"

module Rubyroad
  class CLI
    def self.start(argv)
      new.start(argv)
    end

    def start(argv)
      argv = argv.dup
      argv = default_integrate_argv if argv.empty?

      if argv.first&.start_with?("-")
        return integrate(argv)
      end

      command = argv.shift
      case command
      when "integrate"
        integrate(argv)
      when "generate", "g"
        integrate(argv)
      when "demo", "web"
        demo_ui(argv)
      when "version", "-v", "--version"
        puts "rubyroad #{VERSION}"
        0
      when "help", "-h", "--help", nil
        puts help_text
        0
      else
        if looks_like_spec?(command)
          integrate([command, *argv])
        else
          warn "Unknown command: #{command.inspect}"
          warn help_text
          1
        end
      end
    rescue InvalidSpecError, SpecLoadError => e
      warn "rubyroad: #{e.message}"
      1
    rescue Error => e
      warn "rubyroad: #{e.message}"
      1
    end

    private

    def default_integrate_argv
      ["--spec", Integrator::DEFAULT_SPEC, "--provider", "novapay", "--lang", "ruby"]
    end

    def looks_like_spec?(value)
      value.to_s.match?(/\.(ya?ml|json)\z/i) || value.to_s.match?(%r{\Ahttps?://}i)
    end

    def integrate(argv)
      options = { spec: nil, provider: nil, lang: "ruby", out: Integrator::DEFAULT_OUT, force: nil, overrides: nil }
      force_set = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ./integrate --spec provider_api.yaml --provider novapay --lang ruby"
        opts.on("--spec PATH", "OpenAPI 3 YAML/JSON file or URL") { |v| options[:spec] = v }
        opts.on("--provider NAME", "Provider slug (e.g. novapay)") { |v| options[:provider] = v }
        opts.on("--lang LANG", "Target language (only ruby is supported)") { |v| options[:lang] = v }
        opts.on("--out DIR", "Drop directory for the three artifacts (default: ./output)") { |v| options[:out] = v }
        opts.on("--name NAME", "Alias for --provider") { |v| options[:provider] = v }
        opts.on("--force", "Overwrite an existing service file (required when --out is not ./output)") do
          options[:force] = true
          force_set = true
        end
        opts.on("--overrides PATH", "Generic YAML/JSON pin-file (amount_unit, required_if, signature_encoding)") { |v| options[:overrides] = v }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          return 0
        end
      end
      parser.parse!(argv)
      options[:spec] ||= argv.shift
      options[:spec] ||= Integrator::DEFAULT_SPEC
      options[:provider] ||= File.basename(options[:spec], ".*")
      options[:force] = nil unless force_set

      puts "Parsing spec..."
      result = Integrator.generate(
        spec: options[:spec],
        provider: options[:provider],
        out: options[:out],
        lang: options[:lang],
        overrides: options[:overrides],
        force: options[:force],
        copy_rails: false
      )
      print_integrate_summary(result)
      0
    end

    def demo_ui(argv)
      options = { port: 4567, bind: "127.0.0.1" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rubyroad demo [--port PORT]"
        opts.on("--port PORT", Integer, "Port (default: 4567)") { |v| options[:port] = v }
        opts.on("--bind ADDR", "Bind address (default: 127.0.0.1)") { |v| options[:bind] = v }
      end
      parser.parse!(argv)
      require_relative "web"
      url = "http://#{options[:bind]}:#{options[:port]}"
      $stdout.puts "Demo UI #{url} — same generate process as ./integrate"
      $stdout.flush
      DemoUI.run!(bind: options[:bind], port: options[:port])
      0
    end

    def print_integrate_summary(result)
      profile = result.fetch(:profile)
      endpoints = profile.endpoint_list
      wrapped = wrap_endpoints(endpoints)
      puts "Found #{endpoints.size} endpoint#{'s' if endpoints.size != 1}: #{wrapped}"
      puts "Auth: #{profile.auth_summary}"
      puts "Webhook signature: #{webhook_line(profile)}"
      puts "Generating service..."
      puts "Generating integration guide..."
      puts "Generating test fixtures..."
      result.fetch(:warnings).each do |warning|
        puts "Warning: #{warning}"
      end
      puts
      puts "Output:"
      result.fetch(:files).each do |path|
        display = path.sub(%r{\A#{Regexp.escape(Dir.pwd)}/?}, "./")
        puts "  #{display}"
      end
    end

    def webhook_line(profile)
      profile.webhook_summary
    end

    def wrap_endpoints(endpoints)
      return endpoints.join(", ") if endpoints.join(", ").length <= 72

      first = endpoints.take(3).join(", ")
      rest = endpoints.drop(3).join(", ")
      "#{first},\n                  #{rest}"
    end

    def help_text
      <<~HELP
        RubyRoad #{VERSION} — генератор provider-сервиса выплат Space Payments из OpenAPI 3.x

        Usage:
          ./integrate --spec provider_api.yaml --provider novapay --lang ruby
          rubyroad generate --spec examples/provider_api.yaml --provider novapay --lang ruby
          rubyroad generate --spec spec.yaml --provider name --lang ruby --out app/services/provider --force
          rubyroad generate --spec spec.yaml --provider name --lang ruby --overrides pins.yaml
          rubyroad demo
          rubyroad version
          rubyroad help

        Результат (только --out, по умолчанию ./output):
          <out>/<provider>_service.rb
          <out>/INTEGRATION.md
          <out>/fixtures.json

        --force нужен, если --out не ./output и файл сервиса уже есть.
        request_method — логическое действие (create/status/check/cancel) или payment_method шлюза, не HTTP.

        Без нейросетей и AI-агентов в коде: разбор OpenAPI и ERB.
      HELP
    end
  end
end
