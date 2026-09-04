# frozen_string_literal: true

RSpec.describe "sample spec probes" do
  def example_path(name)
    File.join(repo_root, "examples", name)
  end

  def generate_example(name, provider:)
    path = example_path(name)
    skip "#{name} not present locally" unless File.file?(path)

    dest = File.join(Dir.mktmpdir("rubyroad-probe"), "out")
    result = Rubyroad::Integrator.generate(
      spec: path,
      provider: provider,
      out: dest,
      lang: "ruby",
      copy_rails: false,
      force: true
    )
    [result, dest]
  end

  it "binds YooKassa create to /payouts and warns about /payments" do
    result, dest = generate_example("yookassa-openapi-specification.yaml", provider: "yookassa")
    service = File.read(File.join(dest, "yookassa_service.rb"))
    expect(service).to include('full_path("/payouts")')
    expect(service).not_to include('full_path("/payments")')
    expect(result.fetch(:warnings).join).to include("/payments")
    expect(service).to include("def process_callback")
    expect(service).not_to include("verify_signature!")
  end

  it "writes Funds artifacts with a create/path warning or parse note" do
    result, dest = generate_example("yamls_funds.yaml", provider: "funds")
    expect(File).to exist(File.join(dest, "funds_service.rb"))
    expect(File).to exist(File.join(dest, "INTEGRATION.md"))
    expect(File).to exist(File.join(dest, "fixtures.json"))
    joined = (result.fetch(:warnings) + result.fetch(:profile).parse_notes).join(" ")
    expect(joined).to match(/create|path|payout|stub|bound/i)
  end

  it "warns that QiCard POST /payment is not a clear payout create" do
    result, dest = generate_example("qicard-payment-gateway.yaml", provider: "qicard")
    joined = result.fetch(:warnings).join
    expect(joined).to match(/not look like a payout|No create payout/i)
    expect(File).to exist(File.join(dest, "qicard_service.rb"))
  end

  it "rejects stripe-payment.yaml as non-OpenAPI" do
    path = example_path("stripe-payment.yaml")
    skip "stripe-payment.yaml not present locally" unless File.file?(path)

    dest = File.join(Dir.mktmpdir("rubyroad-stripe"), "out")
    expect do
      Rubyroad::Integrator.generate(
        spec: path,
        provider: "stripe",
        out: dest,
        lang: "ruby",
        copy_rails: false,
        force: true
      )
    end.to raise_error(Rubyroad::InvalidSpecError, /openapi/i)
    expect(Dir.glob(File.join(dest, "*_service.rb"))).to be_empty
  end
end
