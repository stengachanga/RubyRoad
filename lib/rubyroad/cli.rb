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
      when "generate-client"
        generate_client(argv)
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
      options = { spec: nil, provider: nil, lang: "ruby", out: "output", force: true }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ./integrate --spec provider_api.yaml --provider novapay --lang ruby"
        opts.on("--spec PATH", "OpenAPI 3 YAML/JSON file or URL") { |v| options[:spec] = v }
        opts.on("--provider NAME", "Provider slug (e.g. novapay)") { |v| options[:provider] = v }
        opts.on("--lang LANG", "Target language (only ruby is supported)") { |v| options[:lang] = v }
        opts.on("--out DIR", "Output directory (default: ./output)") { |v| options[:out] = v }
        opts.on("--name NAME", "Alias for --provider") { |v| options[:provider] = v }
        opts.on("--force", "Overwrite output files") { options[:force] = true }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          return 0
        end
      end
      parser.parse!(argv)
      options[:spec] ||= argv.shift
      options[:spec] ||= Integrator::DEFAULT_SPEC
      options[:provider] ||= File.basename(options[:spec], ".*")

      puts "Parsing spec..."
      result = Integrator.generate(
        spec: options[:spec],
        provider: options[:provider],
        out: options[:out],
        lang: options[:lang]
      )
      print_integrate_summary(result)
      0
    end

    def generate_client(argv)
      options = { out: nil, name: nil, force: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rubyroad generate-client SPEC_PATH [--out DIR] [--name NAME]"
        opts.on("--out DIR", "Output directory (default: ./generated/<provider>)") { |v| options[:out] = v }
        opts.on("--name NAME", "Gem/module name override") { |v| options[:name] = v }
        opts.on("--force", "Overwrite an existing output directory") { options[:force] = true }
      end
      parser.parse!(argv)
      spec = argv.shift
      if spec.nil? || spec.start_with?("-")
        warn "rubyroad: SPEC_PATH is required"
        return 1
      end

      result = Generator.generate(spec, out: options[:out], name: options[:name], force: options[:force])
      print_client_summary(result)
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
      if result[:rails_path]
        rails = result[:rails_path].sub(%r{\A#{Regexp.escape(Dir.pwd)}/?}, "./")
        puts "  #{rails}  (Space Payments layout)"
      end
    end

    def webhook_line(profile)
      return "(none described)" unless profile.analysis.has_webhooks

      "#{profile.analysis.webhook_header} (HMAC-#{profile.analysis.webhook_algorithm})"
    end

    def wrap_endpoints(endpoints)
      return endpoints.join(", ") if endpoints.join(", ").length <= 72

      first = endpoints.take(3).join(", ")
      rest = endpoints.drop(3).join(", ")
      "#{first},\n                  #{rest}"
    end

    def print_client_summary(result)
      analysis = result.fetch(:analysis)
      puts "RubyRoad #{VERSION} Faraday client"
      puts "  spec:     #{result.fetch(:source)}"
      puts "  provider: #{analysis.title} (#{analysis.module_name})"
      puts "  out:      #{result.fetch(:out)}"
      puts "  Next: cd #{result.fetch(:out)} && bundle install && bundle exec rspec"
    end

    def help_text
      <<~HELP
        RubyRoad #{VERSION} — generate a Space Payments provider service from OpenAPI 3.x

        Usage:
          ./integrate --spec provider_api.yaml --provider novapay --lang ruby
          rubyroad generate --spec examples/provider_api.yaml --provider novapay --lang ruby
          rubyroad generate-client SPEC_PATH [--out DIR] [--name NAME]
          rubyroad version
          rubyroad help

        Primary output (hackathon demo):
          ./output/<provider>_service.rb
          ./output/INTEGRATION.md
          ./output/fixtures.json

        No neural nets: parsing and codegen are Ruby + ERB only.
      HELP
    end
  end
end
