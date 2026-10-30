# Throttlebeam

Keyed debounce, throttle and idempotency primitives on OTP.

Every key gets its own short-lived process, started on demand under a
`DynamicSupervisor` and found through a `Registry`. A busy key never
queues behind an unrelated one, and nothing is left running once a
key's work is done.

## Installation

```elixir
def deps do
  [
    {:throttlebeam, "~> 0.2.0"}
  ]
end
```

The application starts its own supervision tree. There is nothing to
add to yours.

Plug is an optional dependency. Add `{:plug, "~> 1.14"}` to your own
deps if you want the HTTP middleware; Phoenix apps already have it.

## Debounce vs throttle

**Debounce** waits for a quiet period. Every call for a key resets the
timer, and the function runs once calls for that key stop arriving for
the full delay. Use it for autosave or search-as-you-type.

**Throttle** runs the first call for a key immediately and rejects
further calls until the interval has passed. Use it to cap how often an
expensive action can fire.

```elixir
# Runs once, 300ms after the last call for "search:user_42".
:ok = Throttlebeam.Debounce.call("search:user_42", 300, fn -> Search.run(query) end)

# Runs now and returns :executed, or returns :throttled inside the window.
case Throttlebeam.Throttle.call("save_draft:doc_9", 2_000, fn -> Drafts.save(doc) end) do
  :executed -> :ok
  :throttled -> :skipped
end
```

Throttle is leading edge: calls inside the window are dropped, not
deferred to the end of it.

The function runs inside the key's own process. A slow function only
delays that key, but a throttled caller waits for it to finish, so keep
the function short or hand heavy work to a `Task`.

## Idempotency

Run an operation at most once per key. A client that retries a request
sends the same key, and gets the first request's result back instead of
running the operation again. This includes duplicates that arrive while
the first request is still running: they wait for it and share its
result.

```elixir
case Throttlebeam.Idempotency.run(idempotency_key, fn -> Payments.charge(order) end,
       scope: tenant_id,
       fingerprint: order.id
     ) do
  {:ok, charge} -> charge                  # ran in this call
  {:replay, charge} -> charge              # another call already ran it
  {:error, :fingerprint_mismatch} -> ...   # key reused for a different request
  {:error, :timeout} -> ...                # the first request is still running
end
```

| Option | Default | Meaning |
|---|---|---|
| `:scope` | `nil` | Namespace for keys, for example a tenant id |
| `:fingerprint` | `nil` | Describes the request; a reused key with a different fingerprint is rejected |
| `:ttl` | 24 hours | How long a completed result is replayed |
| `:lease` | 30 seconds | How long the first request may hold the key; set it above your slowest operation |
| `:wait_timeout` | 30 seconds | How long a duplicate waits for the first request |

If the function raises, the key is released so a retry can run it again.
If the process running it dies, a waiting duplicate takes over.

Lower-level `reserve/2`, `complete/3` and `release/2` are available when
the result is produced somewhere other than a single function call.

### Plug middleware

```elixir
plug Plug.Parsers, parsers: [:json], json_decoder: Jason
plug Throttlebeam.Plug.Idempotency, scope: &MyApp.Tenancy.id/1
plug :match
plug :dispatch
```

Requests carrying an `Idempotency-Key` header run once; repeats get the
stored status, body and content type back with an
`idempotent-replayed: true` header.

| Situation | Response |
|---|---|
| Key reused with a different method, path, query or body | `422` |
| Duplicate waited past `:wait_timeout`, or the original outlived its `:lease` | `409` |
| Key over 255 bytes, or more than one key header | `400` |
| Handler returned `5xx` | Not stored; the retry runs again |

Put it after `Plug.Parsers` so the body is part of the fingerprint, and
before `:match` so a replay skips routing. Only `POST` and `PATCH` are
guarded by default; pass `methods:` to change that.

## How results are stored

Processes exist only while a request is in flight. Completed results
live in an ETS table, are checked for expiry on every read, and are
swept once a minute. Restarting the application clears stored results,
which has the same effect as them expiring early.

Results are kept in memory on the node that served the request. Across
several nodes, route a given key to the same node or use a shared store.

## License

MIT, see [LICENSE](LICENSE).
