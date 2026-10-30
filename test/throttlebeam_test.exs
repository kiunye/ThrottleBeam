defmodule ThrottlebeamTest do
  use ExUnit.Case, async: true

  test "the application starts the registry, result store and key supervisor" do
    assert is_pid(Process.whereis(Throttlebeam.Registry))
    assert is_pid(Process.whereis(Throttlebeam.Idempotency.Store))
    assert is_pid(Process.whereis(Throttlebeam.DynamicSupervisor))
  end
end
