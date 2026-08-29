# frozen_string_literal: true

RSpec.describe Rubyroad::Analyzer do
  let(:analysis) do
    document = Rubyroad::SpecLoader.load(acme_spec_path)
    described_class.new(document).analyze
  end

  it "names the gem from the spec title" do
    expect(analysis.gem_name).to eq("acme_pay")
    expect(analysis.module_name).to eq("AcmePay")
  end

  it "picks sandbox and live servers" do
    expect(analysis.sandbox_url).to eq("https://sandbox.acmepay.test/v1")
    expect(analysis.live_url).to eq("https://api.acmepay.test/v1")
  end

  it "extracts one operation per documented path verb" do
    names = analysis.operations.map(&:method_name)
    expect(names).to include(
      "create_payment",
      "retrieve_payment",
      "create_refund",
      "list_customers",
      "create_customer"
    )
  end

  it "flags idempotency and bearer auth" do
    expect(analysis.has_idempotency).to be true
    expect(analysis.auth_kind).to eq(:bearer)
    expect(analysis.operations.find { |op| op.method_name == "create_payment" }.has_idempotency).to be true
  end

  it "discovers webhook events and the HMAC header" do
    expect(analysis.has_webhooks).to be true
    expect(analysis.webhook_events.map(&:type)).to include(
      "payment.succeeded",
      "payment.failed",
      "refund.completed"
    )
    expect(analysis.webhook_header).to eq("X-Acme-Signature")
  end

  it "treats integer amount fields as money" do
    payment = analysis.schema_named("Payment")
    amount = payment.properties.find { |prop| prop.name == "amount" }
    expect(amount.money).to be true
    expect(payment.money_like).to be true
  end
end
