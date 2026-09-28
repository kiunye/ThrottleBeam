defmodule Throttlebeam.Debounce do
  @moduledoc """
  Debounce a function call by key. Every call for the same key
  resets the delay, the function only runs once calls for that
  key stop arriving for the full delay period.
  """

  alias Throttlebeam.KeyServer

  def call(key, delay_ms, fun) when is_function(fun, 0) do
    KeyServer.request(key, {:debounce, fun, delay_ms})
  end
end
