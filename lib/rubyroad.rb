# frozen_string_literal: true

require_relative "rubyroad/version"
require_relative "rubyroad/error"
require_relative "rubyroad/inflector"
require_relative "rubyroad/spec_loader"
require_relative "rubyroad/analyzer"
require_relative "rubyroad/integrator"
require_relative "rubyroad/cli"
require_relative "provider"

module Rubyroad
  def self.templates_path
    File.expand_path("rubyroad/templates", __dir__)
  end

  def self.root
    File.expand_path("..", __dir__)
  end
end
