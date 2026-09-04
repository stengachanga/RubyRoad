# frozen_string_literal: true

require "faraday"
require "json"

# Space Payments provider contract. Generated services subclass this.
# The host app (or this repo's tests) supplies credentials and persistence
# hooks; approve_operation / reject_operation are no-ops here so the
# generated file is loadable Ruby without the rest of Space Payments.
module Provider
  class Error < StandardError; end
  class RateLimitError < Error; end
  class UnauthorizedError < Error; end
  class SignatureError < Error; end

  class BaseService
    attr_reader :credentials, :logger

    def initialize(credentials: {}, logger: nil)
      @credentials = stringify_keys(credentials)
      @logger = logger
    end

    # request_method is a logical action (create, status, check, cancel)
    # or a gateway payment_method (e.g. sbp, card) — not an HTTP verb.
    def check_conditions(_operation, _request_method)
      success
    end

    def create_request(_operation, _request_method = :create)
      failure(:not_implemented, "create_request must be generated from the OpenAPI spec")
    end

    def process_callback(_payload)
      failure(:not_implemented, "process_callback must be generated from the OpenAPI spec")
    end

    def fetch_status(_operation)
      failure(:not_implemented, "fetch_status must be generated from the OpenAPI spec")
    end

    def success(data = {})
      { success: true }.merge(data)
    end

    def failure(code, message, extra = {})
      { success: false, error: code, message: message }.merge(extra)
    end

    def client
      raise NotImplementedError, "generated services define client against the spec base URL"
    end

    def auth_headers
      {}
    end

    # Persistence hooks. Space Payments overrides these to update the Operation.
    def approve_operation(operation, attrs = {})
      logger&.info("approve_operation #{operation_id(operation)} #{attrs.inspect}")
      operation
    end

    def reject_operation(operation, attrs = {})
      logger&.info("reject_operation #{operation_id(operation)} #{attrs.inspect}")
      operation
    end

    private

    def operation_id(operation)
      return if operation.nil?

      if operation.respond_to?(:id)
        operation.id
      elsif operation.is_a?(Hash)
        operation[:id] || operation["id"]
      end
    end

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
    end
  end
end
