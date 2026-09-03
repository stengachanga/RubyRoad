# RubyRoad

New to Ruby? Start with the [student guide](STUDENTS.md).

**Generate a Space Payments `Provider::*Service` from an OpenAPI 3.x spec.** Parsing and codegen are Ruby + ERB only — there is no neural net in this project.

Space Payments integrations are Ruby services with this contract:

```ruby
class Provider::ExampleService < Provider::BaseService
  def check_conditions(operation, request_method)  # pre-checks
  def create_request(operation, ...)               # create payout/deposit
  def process_callback(payload)                    # webhook
  def fetch_status(operation)                      # status poll
end
```

## 60-second demo

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

Then open:

- `output/novapay_service.rb`
- `output/INTEGRATION.md`
- `output/fixtures.json`

Judges can follow the same path in [DEMO.md](DEMO.md). `rubyroad generate` is an alias of `./integrate`.

```
./integrate --spec provider_api.yaml --provider novapay --lang ruby
```

`--spec` may be a file or an `http(s)` URL. `--lang ruby` is required (other languages warn and still emit Ruby). Default `--out` is `./output`. A copy is also written to `app/services/provider/<provider>_service.rb`.

## Install

Ruby 3.2+ (3.3+ preferred). From this repo:

```bash
bundle install
./integrate --help
```

## CLI

| Command | What it does |
| --- | --- |
| `./integrate --spec FILE --provider NAME --lang ruby` | Parse OpenAPI 3.x and write the three hackathon artifacts |
| `rubyroad generate …` | Same as `./integrate` |
| `rubyroad generate-client SPEC` | Optional Faraday client gem + RSpec (not the judge path) |
| `rubyroad version` / `rubyroad help` | Version / usage |

Invalid specs fail with a clear error (missing `openapi`, Swagger 2.0, broken YAML, unresolvable `$ref`). Unsupported spec features print a **Warning:** line (oauth2, missing status enum, missing create operation, …).

## What gets generated

Primary artifacts from one CLI run:

1. `output/<provider>_service.rb` — Faraday HTTP, auth from `securitySchemes`, HMAC webhook verifier, `STATUS_MAP` / `ERROR_MAP`, `check_conditions` from schema constraints. Subclasses `Provider::BaseService` in this repo.
2. `output/INTEGRATION.md` — auth, methods table, status map, error handling, ProviderGateway JSON, webhook signature formula.
3. `output/fixtures.json` — request/response/callback examples pulled from the spec.

No proprietary libraries. Faraday is the HTTP client (open source).

## Architecture

```
OpenAPI 3.x  →  SpecLoader ($ref resolve)
             →  Analyzer + PayoutProfile
             →  ERB templates in lib/rubyroad/templates/service
             →  output/
```

| Piece | Role |
| --- | --- |
| `lib/rubyroad/spec_loader.rb` | File/URL fetch, YAML/JSON parse, OpenAPI 3.x validation, local `$ref` resolution |
| `lib/rubyroad/analyzer.rb` | Operations, schemas, servers, security, webhook events |
| `lib/rubyroad/integrator.rb` | Classifies create / status / cancel / webhook / balance; writes the three files |
| `lib/provider/base_service.rb` | Space Payments contract (`success` / `failure` / approve / reject) |
| `examples/provider_api.yaml` | Official NovaPay Payout API sample (OpenAPI 3.0.3) |

The generator is stdlib-only (ERB, YAML, Net::HTTP). Generated services `require "faraday"`.

## Sample spec

[`examples/provider_api.yaml`](examples/provider_api.yaml) (also [`examples/novapay.openapi.yaml`](examples/novapay.openapi.yaml) and [`provider_api.yaml`](provider_api.yaml)):

- `POST /payouts`, `GET /payouts/{id}`, `POST /payouts/{id}/cancel`
- `POST /webhooks/payout` with `X-NovaPay-Signature` HMAC-SHA256
- `GET /balance`
- ApiKeyAuth header `X-API-Key`, Idempotency-Key, sandbox + production servers
- Amounts in kopecks; Space Payments `operation.amount` is major units (×100)

## License

MIT. See [LICENSE](LICENSE).
