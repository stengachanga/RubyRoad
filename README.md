# RubyRoad

Генератор интеграций **выплат** Space Payments: OpenAPI 3.x → Ruby `Provider::*Service`. Разбор и кодоген — Ruby + ERB.

Контракт:

```ruby
class Provider::ExampleService < Provider::BaseService
  def check_conditions(operation, request_method)
  def create_request(operation, request_method = :create)
  def process_callback(payload)
  def fetch_status(operation)
end
```

`request_method` — логическое действие (`create` / `status` / `check` / `cancel`) или payment_method шлюза (`sbp`, `card`), не HTTP-метод.

## Запуск за минуту

Ruby 3.2+, Bundler.

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

Артефакты пишутся **только** в `--out` (по умолчанию `./output`):

- `output/novapay_service.rb` — также в git как образец для жюри
- `output/INTEGRATION.md`
- `output/fixtures.json`

В host-приложение:

```bash
rubyroad generate --spec provider.yaml --provider name --lang ruby --out app/services/provider --force
```

`--force` нужен, если `--out` не `./output` и файл сервиса уже есть. Рядом со spec можно положить `<spec>.overrides.yaml` (`amount_unit`, `required_if`, `signature_encoding`) или передать `--overrides`.

Алиас: `rubyroad generate` с теми же флагами. `--spec` — файл или `http(s)` URL. `--lang ruby` обязателен. Demo UI (бонус, тот же процесс):

```bash
bundle exec ruby exe/rubyroad demo
```

Окно терминала не закрывать. Когда появится `Demo UI http://127.0.0.1:4567` — открыть этот адрес (загрузка spec или пример NovaPay).

Подробный прогон: [DEMO.md](DEMO.md). Для тех, кто не писал на Ruby: [STUDENTS.md](STUDENTS.md).

## CLI

| Команда | Что делает |
| --- | --- |
| `./integrate --spec FILE --provider NAME --lang ruby` | Разобрать OpenAPI 3.x и записать три артефакта в `--out` |
| `rubyroad generate …` | То же |
| `rubyroad demo` | Demo UI на Sinatra |
| `rubyroad version` / `rubyroad help` | Версия / справка |

Невалидная spec — понятная ошибка (нет `openapi`, Swagger 2.0, битый YAML, `$ref`). Лишний path — **Warning:**, генерация не падает. Несколько похожих операций — ближайший payout и комментарий `Parse note`. Факты только из `description` (копейки, `required_if`, encoding HMAC) — **TODO/Warning** и опциональный общий файл `--overrides` / `<spec>.overrides.yaml` (`amount_unit`, `required_if`, `signature_encoding`). Это механизм, не хардкод провайдера. Callback без явного пути и HMAC в spec — `process_callback` ничего не делает.

## Что получается

1. Provider-сервис: Faraday, auth из `securitySchemes`, HMAC webhook, `STATUS_MAP` / `ERROR_MAP`, `check_conditions` из ограничений схемы. Наследует **host** `Provider::BaseService`.
2. `INTEGRATION.md` — авторизация, методы, статусы, ошибки, JSON подключения, формула подписи.
3. `fixtures.json` — примеры из spec.

Ключи API и callback secret задаются вручную в host credentials (`NOVAPAY_API_KEY`, `NOVAPAY_CALLBACK_SECRET` или `credentials`). Остальное берётся из spec и operation.

## Архитектура

```
OpenAPI 3.x  →  SpecLoader ($ref)
             →  Analyzer + PayoutProfile
             →  ERB lib/rubyroad/templates/service
             →  --out/  (три файла)
```

| Часть | Роль |
| --- | --- |
| `lib/rubyroad/spec_loader.rb` | Файл/URL, YAML/JSON, только OpenAPI 3.x, локальные `$ref` |
| `lib/rubyroad/analyzer.rb` | Операции, схемы, servers, security, webhook-события |
| `lib/rubyroad/integrator.rb` | create / status / cancel / webhook / balance; три файла |
| `lib/provider/base_service.rb` | In-repo stub для тестов (host app подставляет свой BaseService) |
| `lib/rubyroad/web.rb` | Demo UI |
| `lib/rubyroad/overrides.rb` | Общий pin-файл: amount_unit, required_if, signature_encoding |
| `examples/provider_api.yaml` | Пример NovaPay (выплаты, OpenAPI 3.0.3) |
| `examples/provider_api.overrides.yaml` | Канон задания для этой spec (копейки, sbp/card, HMAC hex) |

Универсальность — эвристики по путям и методам, не хардкод NovaPay. Второй bundled-спеки нет: жюри смотрит код.

Лицензия MIT. Faraday и Sinatra — открытый исходный код.
