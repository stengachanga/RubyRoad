# RubyRoad

New to Ruby? Start with the [student guide](STUDENTS.md).

**Generate a payment-provider Ruby client, docs, and tests from an OpenAPI 3.x spec.**

Point RubyRoad at a processor's OpenAPI document (Stripe-shaped, Adyen-shaped, or the bundled fictional Acme Pay spec). It emits a Faraday integration blank the merchant can drop into an app: real operation methods, integer-cents money, inferred auth, webhook HMAC verification, Markdown docs, and WebMock-backed RSpec examples that pass offline.

```
bundle exec rubyroad generate SPEC_PATH --out DIR [--name NAME]
```

`SPEC_PATH` may be a file or an `http(s)` URL. `--out` defaults to `./generated/<provider>`.

## 60-second demo

```bash
bundle install
bundle exec rubyroad generate examples/acme_pay.openapi.yaml
cd generated/acme_pay
bundle install
bundle exec rspec
```

That produces a working `AcmePay` gem (`Client#create_payment`, `#retrieve_payment`, `#create_refund`, `#list_customers`, `#create_customer`) plus webhook tests. Judges can follow the exact same path in [DEMO.md](DEMO.md).

## Install

Ruby 3.2+ (3.3+ preferred). From this repo:

```bash
bundle install
bundle exec rubyroad help
```

The gem is named `rubyroad` to match the repository. After packaging:

```bash
gem install rubyroad
rubyroad generate path/to/openapi.yaml
```

## CLI

| Command | What it does |
| --- | --- |
| `rubyroad generate SPEC [--out DIR] [--name NAME] [--force]` | Parse OpenAPI 3.0/3.1 YAML or JSON and write the client, docs, and specs |
| `rubyroad version` | Print `rubyroad 0.1.0` |
| `rubyroad help` | Usage |

Invalid specs fail with a clear error (missing `openapi`, Swagger 2.0, broken YAML, unresolvable `$ref`, download failure).

## What gets generated

### 1. Integration blank

- Gemfile / gemspec / README for the generated client
- Faraday wrapper with configurable sandbox vs live base URL and timeouts
- Auth adapter from `securitySchemes` (Bearer, API key header, HTTP Basic)
- One Ruby method per operation (`operationId` or verb+path), keyword args from parameters + JSON body
- Models from `components/schemas` (Payment, Refund, Customer, WebhookEvent, Error, …)
- `Idempotency-Key` support when the spec declares that header
- Money as **integer minor units + currency** — `Float` raises
- Config: `api_key`, `secret`, `environment`, `logger`, `webhook_secret`
- Webhook verifier + Rack-style endpoint when callbacks/webhooks exist (HMAC-SHA256)

TODO comments appear only where a human must confirm provider-specific gaps (exact signed-string format, unusual auth).

### 2. Documentation

- `README.md` — install, configure, first payment, webhook, tests
- `docs/API.md` — every operation, signature, example request/response
- `docs/AUTH.md` — schemes from the spec
- Mermaid pay-then-webhook sequence in the README when webhooks exist

### 3. Test examples

- Unit tests with WebMock stubs built from OpenAPI examples
- Happy path + error path per resource
- Webhook signature tests when webhooks exist
- Fixtures extracted from the spec
- `bundle exec rspec` in the output directory is green with **no live network**

## Architecture

```
OpenAPI 3.x  →  SpecLoader ($ref resolve)
             →  Analyzer (operations, auth, money, webhooks)
             →  Codegen + ERB templates in lib/rubyroad/templates
             →  generated/<provider>/
```

| Piece | Role |
| --- | --- |
| `lib/rubyroad/spec_loader.rb` | File/URL fetch, YAML/JSON parse, OpenAPI 3.x validation, local `$ref` resolution |
| `lib/rubyroad/analyzer.rb` | Turns the document into operations, schemas, servers, security, webhook events |
| `lib/rubyroad/codegen.rb` | Emits method bodies, models, Markdown, WebMock regexes |
| `lib/rubyroad/generator.rb` | Renders ERB templates and fixture JSON |
| `lib/rubyroad/cli.rb` | `generate` / `version` / `help` |
| `examples/acme_pay.openapi.yaml` | Fictional OpenAPI 3.1 payment API used in the demo |

No runtime gems — the generator is stdlib-only (ERB, YAML, Net::HTTP). The **generated** client depends on Faraday; its test suite depends on RSpec + WebMock.

## Sample spec

[`examples/acme_pay.openapi.yaml`](examples/acme_pay.openapi.yaml) is a realistic Acme Pay API:

- `POST /payments`, `GET /payments/{id}`, `POST /payments/{id}/refunds`
- `GET /customers`, `POST /customers`
- Webhooks `payment.succeeded`, `payment.failed`, `refund.completed` with `X-Acme-Signature` HMAC-SHA256
- Bearer (and alternate API-key) auth, `Idempotency-Key`, sandbox + live servers
- JSON schemas and examples on every operation

## License

MIT. See [LICENSE](LICENSE).
