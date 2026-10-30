# Changelog

## 0.2.0

### Added

- `Throttlebeam.Idempotency`: run an operation at most once per key,
  with concurrent duplicates waiting for and sharing the first result.
  Supports tenant scoping, request fingerprints, a TTL for stored
  results and a lease for in-flight requests.
- `Throttlebeam.Plug.Idempotency`: `Idempotency-Key` middleware for
  Plug and Phoenix. Compiled only when Plug is available.
- Plug as an optional dependency.

### Fixed

- Retrying a call that reached a stopping per-key server could loop
  forever if the supervision tree was down. Retries are now capped, and
  each retry waits for the stopping server to exit so it always reaches
  a fresh one.
- README described an API that did not exist. It now documents the
  actual modules.
- Package link pointed to the wrong GitHub URL casing.

### Removed

- The generated `Throttlebeam.hello/0` placeholder.

## 0.1.0

- Initial release: `Throttlebeam.Debounce` and `Throttlebeam.Throttle`.
