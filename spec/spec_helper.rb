# frozen_string_literal: true

require "bundler/setup"
require "json"
require "rubyroad"
require "fileutils"
require "tmpdir"
require "webmock/rspec"

WebMock.disable_net_connect!

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.order = :defined
  config.filter_run_when_matching :focus
end

module SpecHelpers
  def repo_root
    File.expand_path("..", __dir__)
  end

  def novapay_spec_path
    File.join(repo_root, "examples/provider_api.yaml")
  end

  def fixture_path(name)
    File.join(repo_root, "spec/fixtures", name)
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
end
