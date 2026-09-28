defmodule Throttlebeam.Throttle do
  @moduledoc """
  Throttle a function call by key, leading edge. The first call in
  a window runs immediately, subsequent calls within the same
  window are rejected until it expires.
  """

  alias Throttlebeam.KeyServer

  def call(key, interval_ms, fun) when is_function(fun, 0) do
    KeyServer.request(key, {:throttle, fun, interval_ms})
  end
end
