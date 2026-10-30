defmodule Throttlebeam do
  @moduledoc """
  Keyed debounce, throttle and idempotency primitives on OTP.

    * `Throttlebeam.Debounce` - run a function once calls for a key go quiet.
    * `Throttlebeam.Throttle` - run at most once per interval for a key.
    * `Throttlebeam.Idempotency` - run an operation at most once per key.
    * `Throttlebeam.Plug.Idempotency` - the same, as Plug middleware.

  Each key is served by its own short-lived process, so keys never
  queue behind each other.
  """
end
