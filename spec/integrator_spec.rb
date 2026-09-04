# frozen_string_literal: true

RSpec.describe Rubyroad::Integrator do
  def generate_novapay(dest = nil)
    dest ||= File.join(Dir.mktmpdir("rubyroad-integrate"), "output")
    described_class.generate(
      spec: novapay_spec_path,
      provider: "novapay",
      out: dest,
      lang: "ruby",
      copy_rails: false
    )
  end

  it "writes the three hackathon artifacts for NovaPay" do
    dest = File.join(Dir.mktmpdir("rubyroad-integrate"), "output")
    generate_novapay(dest)

    service_path = File.join(dest, "novapay_service.rb")
    guide_path = File.join(dest, "INTEGRATION.md")
    fixtures_path = File.join(dest, "fixtures.json")

    expect(File).to exist(service_path)
    expect(File).to exist(guide_path)
    expect(File).to exist(fixtures_path)

    service = File.read(service_path)
    expect(service).to include("def check_conditions")
    expect(service).to include("def create_request")
    expect(service).to include("def process_callback")
    expect(service).to include("def fetch_status")
    expect(service).to include("STATUS_MAP")
    expect(service).to include("class Provider::NovapayService")

    guide = File.read(guide_path)
    expect(guide).to match(/Auth/i)
    expect(guide).to include("X-API-Key")
    expect(guide).to match(/Status mapping/i)
    expect(guide).to include("| `completed` | `approved` |")

    fixtures = JSON.parse(File.read(fixtures_path))
    expect(fixtures).to have_key("create_request")
    expect(fixtures).to have_key("callback")
    expect(fixtures.dig("create_request", "request", "amount")).to eq(1_500_000)
    expect(fixtures.dig("create_request", "request", "recipient", "phone")).to eq("79001234567")
    expect(fixtures.dig("create_request", "response_201", "id")).to eq("np_7f3a9b2c")
    expect(fixtures.dig("callback", "expected_operation_status")).to eq("approved")
    expect(fixtures.dig("callback_failed", "expected_operation_status")).to eq("rejected")
  end

  it "loads as real Ruby with STATUS_MAP and the four methods" do
    dest = File.join(Dir.mktmpdir("rubyroad-integrate"), "output")
    generate_novapay(dest)
    load File.join(dest, "novapay_service.rb")

    expect(Provider::NovapayService.instance_methods(false)).to include(
      :check_conditions, :create_request, :process_callback, :fetch_status
    )
    expect(Provider::NovapayService::STATUS_MAP).to include(
      "pending" => "in_progress",
      "processing" => "in_progress",
      "completed" => "approved",
      "failed" => "rejected",
      "cancelled" => "rejected"
    )
    expect(Provider::NovapayService::MIN_AMOUNT_MAJOR).to eq(1000)
  end

  it "prints the judge parse summary via the CLI" do
    dest = File.join(Dir.mktmpdir("rubyroad-integrate"), "output")
    status = nil
    expect do
      status = Rubyroad::CLI.start([
        "integrate",
        "--spec", novapay_spec_path,
        "--provider", "novapay",
        "--lang", "ruby",
        "--out", dest
      ])
    end.to output(/Found 5 endpoints/).to_stdout
    expect(status).to eq(0)
    expect(File).to exist(File.join(dest, "novapay_service.rb"))
  end

  it "warns and no-ops process_callback when webhooks live only in OpenAPI webhooks:" do
    dest = File.join(Dir.mktmpdir("rubyroad-webhooks"), "output")
    result = described_class.generate(
      spec: fixture_path("webhooks_block.yaml"),
      provider: "blockpay",
      out: dest,
      lang: "ruby",
      copy_rails: false
    )
    service = File.read(File.join(dest, "blockpay_service.rb"))
    expect(service).to include("def process_callback")
    expect(service).to include("Parse note:")
    expect(service).to include("method is a no-op")
    expect(service).not_to include("verify_signature!")
    expect(service).to include("def create_request")
    expect(result.fetch(:warnings).join).not_to match(/process_callback is generated using/)
  end

  it "binds the closest payout path and comments when several creates exist" do
    dest = File.join(Dir.mktmpdir("rubyroad-two-create"), "output")
    result = described_class.generate(
      spec: fixture_path("two_create_paths.yaml"),
      provider: "twopath",
      out: dest,
      lang: "ruby",
      copy_rails: false
    )
    service = File.read(File.join(dest, "twopath_service.rb"))
    expect(service).to include("POST /payouts")
    expect(service).not_to include("full_path(\"/transfers\")")
    expect(service).to match(/Parse note:.*create_request: bound POST \/payouts/)
    expect(service).to match(/Parse note:.*fetch_status: bound GET \/payouts\/\{id\}/)
    expect(result.fetch(:warnings).join).to include("POST /transfers")
  end

  it "loads NovaPay canon from sibling overrides (kopecks, required_if, HMAC hex)" do
    dest = File.join(Dir.mktmpdir("rubyroad-integrate"), "output")
    generate_novapay(dest)
    service = File.read(File.join(dest, "novapay_service.rb"))
    expect(service).to include("bank_code is required when type=sbp")
    expect(service).to include("card_number is required when type=card")
    expect(service).to include("def create_action?")
    expect(service).to include("SIGNATURE_ENCODING = \"hex\"")
    expect(service).to include("HMAC.hexdigest")
    expect(service).not_to include("# TODO:")
    guide = File.read(File.join(dest, "INTEGRATION.md"))
    expect(guide).to include("assignment canon")
    expect(guide).to include("request_method")
  end

  it "warns TODO when amount_unit and required_if exist only in description" do
    dest = File.join(Dir.mktmpdir("rubyroad-desc"), "output")
    result = described_class.generate(
      spec: fixture_path("description_only.yaml"),
      provider: "prosepay",
      out: dest,
      lang: "ruby",
      copy_rails: false
    )
    joined = result.fetch(:warnings).join
    expect(joined).to include("TODO:")
    expect(joined).to include("amount_unit")
    expect(joined).to include("required_if")
    service = File.read(File.join(dest, "prosepay_service.rb"))
    expect(service).to include("# TODO:")
    expect(service).to include("bank_code is required when type=sbp")
  end

  it "warns about paths that are not bound to provider-service methods" do
    dest = File.join(Dir.mktmpdir("rubyroad-extra"), "output")
    result = described_class.generate(
      spec: fixture_path("extra_path.yaml"),
      provider: "extrapay",
      out: dest,
      lang: "ruby",
      copy_rails: false
    )
    expect(result.fetch(:warnings).join).to include("GET /health")
    expect(File).to exist(File.join(dest, "extrapay_service.rb"))
  end
end

RSpec.describe "NovaPay analyzer" do
  let(:analysis) do
    document = Rubyroad::SpecLoader.load(novapay_spec_path)
    Rubyroad::Analyzer.new(document, name: "novapay").analyze
  end

  it "classifies NovaPay auth, webhooks, and endpoints" do
    expect(analysis.auth_kind).to eq(:api_key)
    expect(analysis.auth_header).to eq("X-API-Key")
    expect(analysis.auth_scheme_key).to eq("ApiKeyAuth")
    expect(analysis.webhook_header).to eq("X-NovaPay-Signature")
    expect(analysis.operations.map { |op| "#{op.http_method.upcase} #{op.path}" }).to include(
      "POST /payouts",
      "GET /payouts/{payout_id}",
      "POST /payouts/{payout_id}/cancel",
      "POST /webhooks/payout",
      "GET /balance"
    )
  end
end
