# Judge demo (about a minute)

From the repository root. Requires Ruby 3.2+ and Bundler. No neural nets — OpenAPI parse + ERB only.

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

(`provider_api.yaml` at the repo root is the same file. `rubyroad generate --spec examples/provider_api.yaml --provider novapay --lang ruby` is an alias.)

Expected stdout includes a parse summary:

```
Parsing spec...
Found 5 endpoints: POST /payouts, GET /payouts/{id}, POST /payouts/{id}/cancel,
                  POST /webhooks/payout, GET /balance
Auth: ApiKeyAuth (header: X-API-Key)
Webhook signature: X-NovaPay-Signature (HMAC-SHA256)
Generating service...
Generating integration guide...
Generating test fixtures...

Output:
  ./output/novapay_service.rb
  ./output/INTEGRATION.md
  ./output/fixtures.json
```

Then read:

```bash
less output/novapay_service.rb
less output/INTEGRATION.md
python3 -m json.tool output/fixtures.json | head
```

`Provider::NovapayService` subclasses `Provider::BaseService` and implements `check_conditions`, `create_request`, `process_callback`, `fetch_status`, plus `STATUS_MAP`. A copy is also at `app/services/provider/novapay_service.rb`.

Optional: Faraday client gem (not the scored path):

```bash
bundle exec rubyroad generate-client examples/acme_pay.openapi.yaml --force
```

There is also `script/demo`, which runs the integrate command for you.
