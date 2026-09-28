defmodule Throttlebeam.DebounceTest do
  use ExUnit.Case, async: true

  alias Throttlebeam.Debounce

  test "only runs once after repeated calls stop" do
    test_pid = self()
    key = "debounce_test_#{System.unique_integer([:positive])}"

    for _ <- 1..5 do
      Debounce.call(key, 50, fn -> send(test_pid, :ran) end)
      Process.sleep(10)
    end

    refute_receive :ran, 40
    assert_receive :ran, 100
    refute_receive :ran, 100
  end
end
