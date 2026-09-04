# RubyRoad

Генератор интеграций **выплат** Space Payments: OpenAPI 3.x → Ruby `Provider::*Service`. Разбор и кодоген — Ruby + ERB. В проекте нет нейросетей и AI-агентов.

Контракт:

```ruby
class Provider::ExampleService < Provider::BaseService
  def check_conditions(operation, request_method)
  def create_request(operation, ...)
  def process_callback(payload)
  def fetch_status(operation)
end
```

## Запуск за минуту

Ruby 3.2+, Bundler.

```bash
bundle install
./integrate --spec examples/provider_api.yaml --provider novapay --lang ruby
```

Артефакты:

- `output/novapay_service.rb` — также в git как образец для жюри
- `output/INTEGRATION.md`
- `output/fixtures.json`

Алиас: `rubyroad generate` с теми же флагами. `--spec` — файл или `http(s)` URL. `--lang ruby` обязателен. Demo UI (бонус, тот же процесс):

```bash
bundle exec rubyroad demo
```

Откройте http://127.0.0.1:4567 — загрузка spec или пример NovaPay.

Подробный прогон: [DEMO.md](DEMO.md). Для тех, кто не писал на Ruby: [STUDENTS.md](STUDENTS.md).

## CLI

| Команда | Что делает |
| --- | --- |
| `./integrate --spec FILE --provider NAME --lang ruby` | Разобрать OpenAPI 3.x и записать три артефакта |
| `rubyroad generate …` | То же |
| `rubyroad demo` | Demo UI на Sinatra |
| `rubyroad version` / `rubyroad help` | Версия / справка |

Невалидная spec — понятная ошибка (нет `openapi`, Swagger 2.0, битый YAML, `$ref`). Неподдерживаемое — строка **Warning:**, генерация не падает (stub / пропуск).

## Что получается

1. Provider-сервис: Faraday, auth из `securitySchemes`, HMAC webhook, `STATUS_MAP` / `ERROR_MAP`, `check_conditions` из ограничений схемы.
2. `INTEGRATION.md` — авторизация, методы, статусы, ошибки, JSON подключения, формула подписи.
3. `fixtures.json` — примеры из spec.

Ключи API и callback secret задаются вручную (`NOVAPAY_API_KEY`, `NOVAPAY_CALLBACK_SECRET` или `credentials`). Остальное берётся из spec и operation.

## Архитектура

```
OpenAPI 3.x  →  SpecLoader ($ref)
             →  Analyzer + PayoutProfile
             →  ERB lib/rubyroad/templates/service
             →  output/
```

| Часть | Роль |
| --- | --- |
| `lib/rubyroad/spec_loader.rb` | Файл/URL, YAML/JSON, только OpenAPI 3.x, локальные `$ref` |
| `lib/rubyroad/analyzer.rb` | Операции, схемы, servers, security, webhook-события |
| `lib/rubyroad/integrator.rb` | create / status / cancel / webhook / balance; три файла |
| `lib/provider/base_service.rb` | Контракт Space Payments |
| `lib/rubyroad/web.rb` | Demo UI |
| `examples/provider_api.yaml` | Пример NovaPay (выплаты, OpenAPI 3.0.3) |

Универсальность — эвристики по путям и методам, не хардкод NovaPay. Второй bundled-спеки нет: жюри смотрит код.

Лицензия MIT. Faraday и Sinatra — открытый исходный код.
