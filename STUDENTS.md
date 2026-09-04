# RubyRoad — если вы недавно на Ruby

## Идея

Магазин отправляет **выплаты** (СБП, карты) через HTTP-API провайдера. У каждого провайдера свой контракт, руками писать адаптер Space Payments долго.

**RubyRoad — CLI.** На вход — OpenAPI spec провайдера. На выход — заготовка под Space Payments:

```ruby
class Provider::ExampleService < Provider::BaseService
  def check_conditions(operation, request_method)
  def create_request(operation, ...)
  def process_callback(payload)
  def fetch_status(operation)
end
```

1. Ruby **provider-сервис** (`output/novapay_service.rb`)
2. Гайд (`output/INTEGRATION.md`)
3. **Fixtures** из примеров spec (`output/fixtures.json`)

Нейросетей в проекте нет — парсер и ERB. Пример в комплекте — **NovaPay**, mock API **выплат**, без боевых ключей. Депозиты / эквайринг в скоуп не входят.

## Запуск

Ruby 3.2+ и Bundler.

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

Печатает разбор spec и пишет три файла. `rubyroad generate` — то же. Плохая spec даёт ошибку, не стек. Лишнее в spec — `Warning:`. Несколько похожих путей — ближайший к payouts и `# Parse note`. Нет явного HMAC-callback в spec — `process_callback` пустой. Текст только в description — TODO + опциональный `<spec>.overrides.yaml`.

Demo UI: `bundle exec ruby exe/rubyroad demo` (терминал не закрывать, затем http://127.0.0.1:4567).

## Как устроен генератор

```
spec → SpecLoader → Analyzer → PayoutProfile → ERB → output/
```

1. **SpecLoader** — файл или URL, YAML/JSON.
2. **Analyzer** — paths, схемы, auth, webhooks.
3. **PayoutProfile** — какое операция create / status / cancel / webhook / balance.
4. **ERB** в `lib/rubyroad/templates/service/`.

## На что смотреть в коде

1. `DEMO.md`
2. `examples/provider_api.yaml` — `POST /payouts`
3. `output/novapay_service.rb` — `create_request` и `STATUS_MAP`
4. `output/fixtures.json`
5. `spec_loader.rb` → `analyzer.rb` → `integrator.rb` → шаблоны
