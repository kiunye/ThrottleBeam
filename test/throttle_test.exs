defmodule Throttlebeam.ThrottleTest do
  use ExUnit.Case, async: true

  alias Throttlebeam.Throttle

  test "only the first call in a window executes" do
    key = "throttle_test_#{System.unique_integer([:positive])}"

    results =
      for _ <- 1..5 do
        Throttle.call(key, 100, fn -> :ok end)
      end

    assert Enum.count(results, &(&1 == :executed)) == 1
    assert Enum.count(results, &(&1 == :throttled)) == 4
  end

  test "runs again once the window expires" do
    key = "throttle_test_expiry_#{System.unique_integer([:positive])}"

    assert Throttle.call(key, 50, fn -> :ok end) == :executed
    assert Throttle.call(key, 50, fn -> :ok end) == :throttled

    # Generous margin over the 50ms window: under load the expiry
    # can be delivered late, and asserting too early would read
    # the window as still active.
    Process.sleep(150)

    assert Throttle.call(key, 50, fn -> :ok end) == :executed
  end
end
