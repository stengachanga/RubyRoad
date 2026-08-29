# frozen_string_literal: true

RSpec.describe Rubyroad::SpecLoader do
  it "loads the bundled Acme Pay OpenAPI 3.1 spec" do
    doc = described_class.load(acme_spec_path)
    expect(doc["openapi"]).to start_with("3.")
    expect(doc.dig("info", "title")).to eq("Acme Pay API")
    expect(doc["paths"]).to have_key("/payments")
  end

  it "resolves local $ref pointers in place" do
    doc = described_class.load(acme_spec_path)
    schema = doc.dig("paths", "/payments", "post", "requestBody", "content", "application/json", "schema")
    expect(schema["properties"]).to have_key("amount")
    expect(schema["x-rubyroad-ref"]).to include("CreatePaymentRequest")
  end

  it "rejects Swagger 2.0" do
    expect { described_class.load(fixture_path("swagger2.yaml")) }
      .to raise_error(Rubyroad::InvalidSpecError, /Unsupported OpenAPI version/)
  end

  it "rejects a YAML object that is not OpenAPI" do
    expect { described_class.load(fixture_path("not_openapi.yaml")) }
      .to raise_error(Rubyroad::InvalidSpecError, /missing 'openapi'/)
  end

  it "rejects a missing file" do
    expect { described_class.load("/tmp/does-not-exist-rubyroad.yaml") }
      .to raise_error(Rubyroad::SpecLoadError, /not found/)
  end

  it "rejects broken YAML" do
    path = File.join(Dir.mktmpdir, "bad.yaml")
    File.write(path, "openapi: [unterminated")
    expect { described_class.load(path) }
      .to raise_error(Rubyroad::InvalidSpecError, /Failed to parse/)
  end

  it "downloads a spec from an http URL" do
    yaml = File.read(acme_spec_path)
    stub_request(:get, "https://specs.example.test/acme.yaml")
      .to_return(status: 200, body: yaml, headers: { "Content-Type" => "application/yaml" })

    doc = described_class.load("https://specs.example.test/acme.yaml")
    expect(doc.dig("info", "title")).to eq("Acme Pay API")
  end

  it "fails clearly when a URL returns an error" do
    stub_request(:get, "https://specs.example.test/missing.yaml")
      .to_return(status: 404, body: "nope")

    expect { described_class.load("https://specs.example.test/missing.yaml") }
      .to raise_error(Rubyroad::SpecLoadError, /HTTP 404/)
  end
end
