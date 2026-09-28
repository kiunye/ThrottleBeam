defmodule Throttlebeam.DebounceTest do
  use ExUnit.Case, async: true

  alias Throttlebeam.Debounce

  test "only runs once after repeated calls stop" do
    test_pid = self()
    key = "debounce_test_#{System.unique_integer([:positive])}"

    for _ <- 1..5 do
      Debounce.call(key, 150, fn -> send(test_pid, :ran) end)
      Process.sleep(20)
    end

    # Nothing may have run yet: the last call reset the timer only
    # ~20ms ago, and even the first call's window (t0 + 150) has not
    # elapsed, so a broken implementation that never resets would
    # fire inside this window.
    refute_receive :ran, 60
    assert_receive :ran, 150
    refute_receive :ran, 100
  end
end
