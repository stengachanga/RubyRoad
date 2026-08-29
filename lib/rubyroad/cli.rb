# frozen_string_literal: true

require "optparse"

module Rubyroad
  class CLI
    def self.start(argv)
      new.start(argv)
    end

    def start(argv)
      argv = argv.dup
      command = argv.shift

      case command
      when "generate", "g"
        generate(argv)
      when "version", "-v", "--version"
        puts "rubyroad #{VERSION}"
        0
      when "help", "-h", "--help", nil
        puts help_text
        0
      else
        warn "Unknown command: #{command.inspect}"
        warn help_text
        1
      end
    rescue InvalidSpecError, SpecLoadError => e
      warn "rubyroad: #{e.message}"
      1
    rescue Error => e
      warn "rubyroad: #{e.message}"
      1
    end

    private

    def generate(argv)
      options = { out: nil, name: nil, force: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rubyroad generate SPEC_PATH [--out DIR] [--name NAME]"
        opts.on("--out DIR", "Output directory (default: ./generated/<provider>)") { |v| options[:out] = v }
        opts.on("--name NAME", "Gem/module name override (e.g. acme_pay)") { |v| options[:name] = v }
        opts.on("--force", "Overwrite an existing output directory") { options[:force] = true }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          return 0
        end
      end
      parser.parse!(argv)
      spec = argv.shift
      if spec.nil? || spec.start_with?("-")
        warn "rubyroad: SPEC_PATH is required"
        warn parser.banner
        return 1
      end

      result = Generator.generate(
        spec,
        out: options[:out],
        name: options[:name],
        force: options[:force]
      )
      print_summary(result)
      0
    end

    def print_summary(result)
      analysis = result.fetch(:analysis)
      files = result.fetch(:files)
      puts "RubyRoad #{VERSION}"
      puts "  spec:     #{result.fetch(:source)}"
      puts "  provider: #{analysis.title} (#{analysis.module_name})"
      puts "  out:      #{result.fetch(:out)}"
      puts
      client_files = files.count { |path| path.start_with?("lib/", "Gemfile", "#{analysis.gem_name}.gemspec") }
      doc_files = files.count { |path| path == "README.md" || path.start_with?("docs/") }
      test_files = files.count { |path| path.start_with?("spec/") }
      puts "  ✓ Integration blank  (#{client_files} files, #{analysis.operations.size} operations)"
      puts "  ✓ Documentation      (#{doc_files} files)"
      puts "  ✓ Test examples      (#{test_files} files)"
      puts
      puts "Next:"
      puts "  cd #{result.fetch(:out)} && bundle install && bundle exec rspec"
    end

    def help_text
      <<~HELP
        RubyRoad #{VERSION} — generate a payment-provider Ruby client from OpenAPI 3.x

        Usage:
          rubyroad generate SPEC_PATH [--out DIR] [--name NAME]
          rubyroad version
          rubyroad help

        SPEC_PATH is a file path or http(s) URL to an OpenAPI 3.0/3.1 YAML or JSON document.

        Options:
          --out DIR     Output directory (default: ./generated/<provider>)
          --name NAME   Override the generated gem name (default: inferred from info.title)
          --force       Overwrite files in an existing output directory

        Example:
          bundle exec rubyroad generate examples/acme_pay.openapi.yaml
      HELP
    end
  end
end
