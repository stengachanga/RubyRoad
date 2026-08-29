# frozen_string_literal: true

require "open3"

RSpec.describe Rubyroad::Generator do
  def generate_acme
    dest = File.join(Dir.mktmpdir("rubyroad"), "acme_pay")
    result = described_class.generate(acme_spec_path, out: dest, force: true)
    [dest, result]
  end

  it "writes a client gem skeleton with real operation methods" do
    dest, result = generate_acme
    expect(File.file?(File.join(dest, "lib/acme_pay/client.rb"))).to be true
    expect(File.file?(File.join(dest, "docs/API.md"))).to be true
    expect(File.file?(File.join(dest, "docs/AUTH.md"))).to be true
    expect(File.file?(File.join(dest, "spec/operations_spec.rb"))).to be true

    client = File.read(File.join(dest, "lib/acme_pay/client.rb"))
    %w[create_payment retrieve_payment create_refund list_customers create_customer].each do |name|
      expect(client).to match(/def #{name}\(.*\n(?:.*\n)*?.*payload = request\(/)
    end
    expect(client).to include("normalize_money_amount(amount)")
    expect(client).to include("Idempotency-Key")

    expect(result[:analysis].operations.size).to eq(5)
  end

  it "emits fixtures extracted from OpenAPI examples" do
    dest, = generate_acme
    fixture = File.join(dest, "spec/fixtures/create_payment_response.json")
    expect(File.file?(fixture)).to be true
    payload = JSON.parse(File.read(fixture))
    expect(payload["id"]).to eq("pay_01J5ACME000000000000001")
    expect(payload["amount"]).to eq(2500)
  end

  it "produces a client whose generated RSpec suite passes offline", :integration do
    dest, = generate_acme
    vendor = File.join(dest, "vendor/bundle")
    env = ENV.to_h.merge(
      "BUNDLE_GEMFILE" => File.join(dest, "Gemfile"),
      "BUNDLE_PATH" => vendor,
      "GEM_HOME" => vendor,
      "BUNDLE_IGNORE_CONFIG" => "1"
    )
    env.delete("BUNDLE_BIN_PATH")
    stdout, stderr, status = Open3.capture3(
      env,
      "bash", "-lc",
      "bundle install --quiet && bundle exec rspec --format progress",
      chdir: dest
    )
    unless status.success?
      warn stdout
      warn stderr
    end
    expect(status).to be_success, "generated suite failed:\n#{stdout}\n#{stderr}"
  end
end
