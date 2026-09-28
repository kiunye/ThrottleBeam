defmodule Throttlebeam.Throttle do
  @moduledoc """
  Throttle a function call by key, leading edge. The first call in
  a window runs immediately, subsequent calls within the same
  window are rejected until it expires.
  """

  alias Throttlebeam.KeyServer

  def call(key, interval_ms, fun) when is_function(fun, 0) do
    ensure_started(key)
    GenServer.call(KeyServer.via(key), {:throttle, fun, interval_ms})
  end

  defp ensure_started(key) do
    case DynamicSupervisor.start_child(
           Throttlebeam.DynamicSupervisor,
           {KeyServer, key: key}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
