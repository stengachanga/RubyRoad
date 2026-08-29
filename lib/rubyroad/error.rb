# frozen_string_literal: true

module Rubyroad
  class Error < StandardError; end

  class InvalidSpecError < Error; end

  class SpecLoadError < Error; end
end
