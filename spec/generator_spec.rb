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
    status = nil
    stdout = +""
    Bundler.with_unbundled_env do
      env = ENV.to_h.merge(
        "GEM_HOME" => vendor,
        "GEM_PATH" => vendor,
        "BUNDLE_PATH" => vendor,
        "PATH" => "/usr/bin:/bin:#{ENV.fetch('PATH')}"
      )
      FileUtils.mkdir_p(vendor)
      install_out, install_err, install_status = Open3.capture3(
        env, "/usr/bin/bundle", "install", chdir: dest
      )
      unless install_status.success?
        status = install_status
        stdout = "#{install_out}\n#{install_err}"
      else
        spec_out, spec_err, spec_status = Open3.capture3(
          env, "/usr/bin/bundle", "exec", "rspec", "--format", "progress", chdir: dest
        )
        status = spec_status
        stdout = "#{spec_out}\n#{spec_err}"
      end
    end
    expect(status).to be_success, "generated suite failed:\n#{stdout}"
  end
end
