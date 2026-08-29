# frozen_string_literal: true

require_relative "lib/rubyroad/version"

Gem::Specification.new do |spec|
  spec.name = "rubyroad"
  spec.version = Rubyroad::VERSION
  spec.authors = ["RubyRoad contributors"]
  spec.email = ["hackathon@rubyroad.dev"]

  spec.summary = "Generate a payment-provider Ruby client, docs, and tests from OpenAPI 3.x"
  spec.description = <<~DESC
    RubyRoad reads a payment provider's OpenAPI 3.0/3.1 specification and
    generates a ready-to-fill Faraday client gem, merchant documentation, and
    WebMock-backed RSpec examples. Auth, idempotency, money (integer minor
    units), and webhook HMAC verification are inferred from the spec.
  DESC
  spec.homepage = "https://github.com/stengachanga/RubyRoad"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*",
      "exe/*",
      "examples/**/*",
      "LICENSE",
      "README.md",
      "DEMO.md"
    ].select { |path| File.file?(path) }
  end
  spec.bindir = "exe"
  spec.executables = ["rubyroad"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.23"
end
