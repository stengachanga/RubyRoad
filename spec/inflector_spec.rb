# frozen_string_literal: true

RSpec.describe Rubyroad::Inflector do
  it "underscores operationIds" do
    expect(described_class.ruby_ident("createPayment")).to eq("create_payment")
  end

  it "builds a gem slug from a title" do
    expect(described_class.slug("Acme Pay API")).to eq("acme_pay")
  end

  it "camelizes a slug into a module name" do
    expect(described_class.camelize("acme_pay")).to eq("AcmePay")
  end
end
