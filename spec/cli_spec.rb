# frozen_string_literal: true

RSpec.describe Rubyroad::CLI do
  it "prints help" do
    expect { described_class.start(["help"]) }.to output(/integrate/).to_stdout
  end

  it "prints the version" do
    expect { described_class.start(["version"]) }.to output(/rubyroad #{Rubyroad::VERSION}/).to_stdout
  end

  it "returns a non-zero status for an unknown command" do
    expect(described_class.start(["explode"])).to eq(1)
  end

  it "returns a non-zero status and a clear error for an invalid spec" do
    status = nil
    expect do
      status = described_class.start(["generate", fixture_path("swagger2.yaml")])
    end.to output(/Parsing spec/).to_stdout.and output(/Unsupported OpenAPI version/).to_stderr
    expect(status).to eq(1)
  end
end
