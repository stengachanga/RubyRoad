# Judge demo (about a minute)

From the repository root. Requires Ruby 3.2+ and Bundler.

```bash
# 1. Install RubyRoad
bundle install

# 2. Generate the Acme Pay client from the bundled OpenAPI 3.1 spec
bundle exec rubyroad generate examples/acme_pay.openapi.yaml

# 3. Install the generated client and run its suite (WebMock, no live network)
cd generated/acme_pay
bundle install
bundle exec rspec
```

Expected: every example green. Open `generated/acme_pay/lib/acme_pay/client.rb` — `create_payment`, `retrieve_payment`, `create_refund`, `list_customers`, and `create_customer` have real Faraday bodies, not empty stubs.

Optional extras:

```bash
# Invalid spec fails clearly
bundle exec rubyroad generate /dev/null
# => rubyroad: Failed to parse OpenAPI document: ...

# Custom output / name
bundle exec rubyroad generate examples/acme_pay.openapi.yaml --out /tmp/acme --name acme_pay --force

# Read the generated merchant docs
less generated/acme_pay/README.md
less generated/acme_pay/docs/API.md
less generated/acme_pay/docs/AUTH.md
```

There is also `script/demo` which runs steps 1–3 for you.
