# Демо для жюри (около минуты)

Из корня репозитория. Ruby 3.2+ и Bundler. Нейросетей нет — OpenAPI + ERB.

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

(`provider_api.yaml` в корне — тот же файл. `rubyroad generate --spec examples/provider_api.yaml --provider novapay --lang ruby` — алиас.)

Ожидаемый stdout:

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

Дальше смотрите `output/` (образец NovaPay уже закоммичен). `Provider::NovapayService` реализует `check_conditions`, `create_request`, `process_callback`, `fetch_status`.

## Demo UI (бонус)

Тот же процесс в браузере: спека файлом или пример NovaPay.

```bash
bundle exec ruby exe/rubyroad demo
```

Терминал оставить открытым. Когда напечатает адрес — открыть http://127.0.0.1:4567

## About на GitHub

Описание репозитория: *«Генератор интеграций выплат Space Payments: OpenAPI → Ruby Provider::BaseService»*.
