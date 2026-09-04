This folder is optional local scaffolding only.

RubyRoad writes the three artifacts to `--out` (default `./output`). To drop a service into a host app:

```bash
rubyroad generate --spec path/to/spec.yaml --provider name --lang ruby --out app/services/provider --force
```

Do not treat this gem’s tree as the Space Payments application. Host apps supply their own `Provider::BaseService`.
