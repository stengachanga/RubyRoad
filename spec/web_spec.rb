# frozen_string_literal: true

require "rack/test"
require "rubyroad/web"

RSpec.describe Rubyroad::DemoUI do
  include Rack::Test::Methods

  def app
    Rubyroad::DemoUI
  end

  it "renders the generate form" do
    get "/"
    expect(last_response).to be_ok
    expect(last_response.body).to include("./integrate")
  end

  it "generates the three artifacts from the bundled NovaPay spec" do
    post "/generate", use_example: "1", provider: "novapay"
    expect(last_response).to be_ok
    expect(last_response.body).to include("def check_conditions")
    expect(last_response.body).to include("INTEGRATION.md")
    expect(last_response.body).to include("fixtures.json")
  end
end
