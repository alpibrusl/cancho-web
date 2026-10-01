# lexsys-web

> **Status: design only.** Nothing here is built. [`docs/design.md`](docs/design.md)
> says what will be, what it takes from FastAPI, and what it deliberately does not.

A web layer for [lex-sys](https://github.com/alpibrusl/lex-sys): routes with typed
parameters, request bodies validated by
[`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema), `problem+json`
errors, and an OpenAPI document generated from the same declarations -- on top of
the `http.server` package that `lex-sys` already ships (`packages/http-server/`).

One thread, a `Poller`, no `Ffi`, no `extern fn`: the compiled server's authority
report names exactly what it can do, and C is not on the list.

## Licence

[EUPL-1.2](LICENSE).
