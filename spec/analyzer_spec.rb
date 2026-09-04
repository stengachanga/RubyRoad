# frozen_string_literal: true

RSpec.describe Rubyroad::Analyzer do
  let(:analysis) do
    document = Rubyroad::SpecLoader.load(novapay_spec_path)
    described_class.new(document, name: "novapay").analyze
  end

  it "names the gem from the provider name" do
    expect(analysis.gem_name).to eq("novapay")
    expect(analysis.module_name).to eq("Novapay")
  end

  it "picks sandbox and live servers" do
    expect(analysis.sandbox_url).to eq("https://api.sandbox.novapay.example/v1")
    expect(analysis.live_url).to eq("https://api.novapay.example/v1")
  end

  it "extracts one operation per documented path verb" do
    names = analysis.operations.map { |op| "#{op.http_method.upcase} #{op.path}" }
    expect(names).to include(
      "POST /payouts",
      "GET /payouts/{payout_id}",
      "POST /payouts/{payout_id}/cancel",
      "POST /webhooks/payout",
      "GET /balance"
    )
  end

  it "flags idempotency and API key auth" do
    expect(analysis.has_idempotency).to be true
    expect(analysis.auth_kind).to eq(:api_key)
    expect(analysis.auth_header).to eq("X-API-Key")
  end

  it "discovers webhook events and the HMAC header" do
    expect(analysis.has_webhooks).to be true
    expect(analysis.webhook_events.map(&:type)).to include("payout.completed", "payout.failed")
    expect(analysis.webhook_header).to eq("X-NovaPay-Signature")
  end

  it "treats integer amount fields as money" do
    payout = analysis.schema_named("PayoutResponse")
    amount = payout.properties.find { |prop| prop.name == "amount" }
    expect(amount.money).to be true
  end
end
