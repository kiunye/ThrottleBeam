# Throttlebeam

Keyed debounce and throttle primitives on top of OTP.

## Debounce vs Throttle

These terms are frequently confused. Here is the distinction:

```
DEBOUNCE: "fire AFTER quiet"              THROTTLE: "fire AT MOST every N"
                                                      + trailing call at end

events:  --|--|--|--                      events:  --|--|--|--|--|--|
                                                  suppressed
                    quiet                                           trailing
                    (target wait)                                   (last intent preserved)

use when: autosave, search-as-you-type     rate-limit API calls, smooth
         coalesce webhook bursts            event stream spikes
```

**Debounce** waits for a quiet period after the last call before firing.
Each new call resets the clock. If you're building a search-as-you-type
box, debounce is what you want — fire the query only after the user
stops typing.

**Throttle** fires immediately on the first call, then suppresses further
calls for the duration of the interval. A trailing call fires at the end
of the interval if any calls arrived during suppression, delivering the
most recent intent. Use throttle for rate-limiting API calls or smoothing
event stream spikes.

## Installation

Add `throttlebeam` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:throttlebeam, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Start a named server under your supervision tree
children = [
  {Throttlebeam, name: MyApp.Throttle, max_keys: 50_000}
]

{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)

# Debounce: fire autosave after 500ms of quiet on this user's key
:ok = Throttlebeam.debounce(MyApp.Throttle, "user:123", 500, fn ->
  MyApp.Repo.autosave(user_id)
end)

# Throttle: fire search at most every 200ms
:ok = Throttlebeam.throttle(MyApp.Throttle, "search:123", 200, fn ->
  MyApp.Search.run(query)
end)

# Cancel a pending timer (e.g. user navigated away)
:ok = Throttlebeam.cancel(MyApp.Throttle, "user:123")

# Inspect a key's state (for debugging/tests)
{:ok, %{mode: :debounce, generation: 3, pending: true}} =
  Throttlebeam.inspect(MyApp.Throttle, "user:123")
```

## Configuration

Options accepted by `start_link/1`, `start_link/2`, and `child_spec/1`:

| Option | Default | Description |
|---|---|---|
| `:name` | — | Atom to register the server process |
| `:max_keys` | 10 000 | Maximum distinct keys per instance |
| `:max_delay` | 60 000 | Maximum allowed delay/interval in ms |
| `:staleness_window_ms` | 300 000 | Idle entries older than this are reaped by sweep |
| `:sweep_interval_ms` | 60 000 | How often the cleanup sweep runs |

## Guarantees

- **No double fires**: generation-tagged timer messages prevent cancelled timers
  from causing duplicate invocations.
- **No missed fires**: the trailing call in throttle guarantees the most recent
  intent during a suppressed window is never silently dropped.
- **Key isolation**: one key's slow or failing callback does not affect other keys.
- **Zero runtime dependencies**: built entirely on OTP primitives.

## Error semantics

| Error | Meaning |
|---|---|
| `{:error, :bad_arg}` | `fun` is not a 0-arity function or `delay` is not a non-negative integer |
| `{:error, :delay_too_large}` | delay exceeds the server's `:max_delay` |
| `{:error, :mode_conflict}` | key is already in the other mode (debounce vs throttle) |
| `{:error, :max_keys_reached}` | key is new and the server's key cap is full |

## Callbacks

Callbacks execute **inline** in the server process. A slow callback will
delay processing of other keys. Keep callback bodies fast, or enqueue
heavy work elsewhere before invoking the library.

Errors raised, thrown, or exited from callbacks are caught and logged
via `Logger.error/1` — one bad callback will not crash the shared server.

## License

MIT — see [LICENSE](LICENSE).
