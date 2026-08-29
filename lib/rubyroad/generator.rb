# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "pathname"

module Rubyroad
  class Generator
    def self.generate(path_or_url, out: nil, name: nil, force: false)
      new(path_or_url, out: out, name: name, force: force).generate
    end

    def initialize(path_or_url, out: nil, name: nil, force: false)
      @source = path_or_url
      @out_override = out
      @name = name
      @force = force
    end

    def generate
      document = SpecLoader.load(@source)
      analysis = Analyzer.new(document, name: @name).analyze
      dest = File.expand_path(@out_override || File.join("generated", analysis.gem_name))
      prepare_destination(dest)
      binding_ctx = TemplateContext.new(analysis)
      written = []

      mapping(analysis).each do |relative, template|
        contents = render(template, binding_ctx)
        write(dest, relative, contents)
        written << relative
      end

      write_fixtures(dest, analysis).each { |relative| written << relative }
      {
        source: @source,
        out: dest,
        analysis: analysis,
        files: written
      }
    end

    private

    def prepare_destination(dest)
      if File.exist?(dest) && !@force && !Dir.exist?(dest)
        raise Error, "Refusing to overwrite #{dest} (not a directory). Pass --force to replace it."
      end

      FileUtils.mkdir_p(dest)
    end

    def mapping(analysis)
      gem = analysis.gem_name
      {
        ".bundle/config" => "client/bundle_config.erb",
        "Gemfile" => "client/gemfile.erb",
        "#{gem}.gemspec" => "client/gemspec.erb",
        ".gitignore" => "client/gitignore.erb",
        ".rspec" => "client/rspec.erb",
        "Rakefile" => "client/rakefile.erb",
        "LICENSE" => "client/license.erb",
        "README.md" => "client/readme.erb",
        "docs/API.md" => "docs/api.md.erb",
        "docs/AUTH.md" => "docs/auth.md.erb",
        "lib/#{gem}.rb" => "client/lib/module.rb.erb",
        "lib/#{gem}/version.rb" => "client/lib/version.rb.erb",
        "lib/#{gem}/errors.rb" => "client/lib/errors.rb.erb",
        "lib/#{gem}/money.rb" => "client/lib/money.rb.erb",
        "lib/#{gem}/models.rb" => "client/lib/models.rb.erb",
        "lib/#{gem}/config.rb" => "client/lib/config.rb.erb",
        "lib/#{gem}/auth.rb" => "client/lib/auth.rb.erb",
        "lib/#{gem}/http.rb" => "client/lib/http.rb.erb",
        "lib/#{gem}/client.rb" => "client/lib/client.rb.erb",
        "lib/#{gem}/webhooks.rb" => "client/lib/webhooks.rb.erb",
        "spec/spec_helper.rb" => "client/spec/spec_helper.rb.erb",
        "spec/money_spec.rb" => "client/spec/money_spec.rb.erb",
        "spec/client_spec.rb" => "client/spec/client_spec.rb.erb",
        "spec/operations_spec.rb" => "client/spec/operations_spec.rb.erb",
        "spec/webhooks_spec.rb" => "client/spec/webhooks_spec.rb.erb"
      }
    end

    def render(template, context)
      path = File.join(Rubyroad.templates_path, template)
      unless File.file?(path)
        raise Error, "Missing template #{template} (expected at #{path})"
      end

      erb = ERB.new(File.read(path), trim_mode: "-")
      erb.filename = path
      erb.result(context.get_binding)
    end

    def write(dest, relative, contents)
      path = File.join(dest, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      if relative.start_with?("exe/") || relative.start_with?("bin/")
        File.chmod(0o755, path)
      end
    end

    def write_fixtures(dest, analysis)
      written = []
      dir = File.join(dest, "spec/fixtures")
      FileUtils.mkdir_p(dir)

      analysis.operations.each do |op|
        success = op.success_example || { "id" => "obj_test_123", "object" => "resource" }
        name = "#{op.fixture_name}_response.json"
        File.write(File.join(dir, name), JSON.pretty_generate(success) + "\n")
        written << "spec/fixtures/#{name}"

        if op.request_example
          name = "#{op.fixture_name}_request.json"
          File.write(File.join(dir, name), JSON.pretty_generate(op.request_example) + "\n")
          written << "spec/fixtures/#{name}"
        end

        error = op.error_example || {
          "error" => {
            "type" => "invalid_request",
            "code" => "parameter_invalid",
            "message" => "The request could not be processed."
          }
        }
        name = "#{op.fixture_name}_error.json"
        File.write(File.join(dir, name), JSON.pretty_generate(error) + "\n")
        written << "spec/fixtures/#{name}"
      end

      analysis.webhook_events.each do |event|
        next unless event.example

        slug = Inflector.underscore(event.type.tr(".", "_"))
        name = "webhook_#{slug}.json"
        File.write(File.join(dir, name), JSON.pretty_generate(event.example) + "\n")
        written << "spec/fixtures/#{name}"
      end

      written
    end
  end

  class TemplateContext
    def initialize(analysis)
      @analysis = analysis
      @codegen = Codegen.new(analysis)
    end

    def analysis
      @analysis
    end

    def codegen
      @codegen
    end

    def a
      @analysis
    end

    def gem_name
      @analysis.gem_name
    end

    def module_name
      @analysis.module_name
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
