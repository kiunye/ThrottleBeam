defmodule Throttlebeam.IdempotencyTest do
  use ExUnit.Case, async: true

  alias Throttlebeam.Idempotency
  alias Throttlebeam.Idempotency.{Server, Store}

  defp unique_key, do: "key-#{System.unique_integer([:positive])}"

  test "runs once, then replays the stored result" do
    key = unique_key()
    counter = :counters.new(1, [])
    fun = fn -> :counters.add(counter, 1, 1) && :counters.get(counter, 1) end

    assert Idempotency.run(key, fun) == {:ok, 1}
    assert Idempotency.run(key, fun) == {:replay, 1}
    assert :counters.get(counter, 1) == 1
  end

  test "concurrent callers on a new key run the work exactly once" do
    key = unique_key()
    counter = :counters.new(1, [])

    results =
      1..20
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Idempotency.run(key, fn ->
            Process.sleep(50)
            :counters.add(counter, 1, 1)
            :charged
          end)
        end)
      end)
      |> Task.await_many(2_000)

    assert :counters.get(counter, 1) == 1
    assert Enum.count(results, &(&1 == {:ok, :charged})) == 1
    assert Enum.count(results, &(&1 == {:replay, :charged})) == 19
  end

  test "a key reused with a different fingerprint is rejected" do
    key = unique_key()

    assert {:ok, :a} = Idempotency.run(key, fn -> :a end, fingerprint: "body-a")

    assert Idempotency.run(key, fn -> :b end, fingerprint: "body-b") ==
             {:error, :fingerprint_mismatch}
  end

  test "a mismatched fingerprint is rejected while the original is still running" do
    key = unique_key()
    test_pid = self()

    owner =
      Task.async(fn ->
        Idempotency.run(
          key,
          fn ->
            send(test_pid, :started)
            Process.sleep(100)
            :a
          end,
          fingerprint: "body-a"
        )
      end)

    assert_receive :started
    assert Idempotency.reserve(key, fingerprint: "body-b") == {:error, :fingerprint_mismatch}
    assert Task.await(owner) == {:ok, :a}
  end

  test "scopes keep identical keys apart" do
    key = unique_key()

    assert {:ok, :tenant_a} = Idempotency.run(key, fn -> :tenant_a end, scope: "tenant-a")
    assert {:ok, :tenant_b} = Idempotency.run(key, fn -> :tenant_b end, scope: "tenant-b")
    assert {:replay, :tenant_a} = Idempotency.run(key, fn -> :other end, scope: "tenant-a")
  end

  test "a raising operation releases the key so a retry can run" do
    key = unique_key()

    assert_raise RuntimeError, fn ->
      Idempotency.run(key, fn -> raise "card declined by network" end)
    end

    assert Idempotency.run(key, fn -> :second_try end) == {:ok, :second_try}
  end

  test "a waiter takes over when the owner dies before completing" do
    key = unique_key()
    test_pid = self()

    owner =
      spawn(fn ->
        :proceed = Idempotency.reserve(key)
        send(test_pid, :reserved)
        Process.sleep(:infinity)
      end)

    assert_receive :reserved
    waiter = Task.async(fn -> Idempotency.reserve(key) end)
    Process.sleep(20)

    Process.exit(owner, :kill)

    assert Task.await(waiter) == :proceed
  end

  test "waiters time out when the owner outlives its lease" do
    key = unique_key()
    test_pid = self()

    spawn(fn ->
      :proceed = Idempotency.reserve(key, lease: 50)
      send(test_pid, :reserved)
      Process.sleep(:infinity)
    end)

    assert_receive :reserved
    assert Idempotency.reserve(key, lease: 50) == {:error, :timeout}
    # The key is free again once the lease has expired.
    assert Idempotency.reserve(key) == :proceed
  end

  test "a duplicate that waits longer than wait_timeout gets an error, not a crash" do
    key = unique_key()
    test_pid = self()

    spawn(fn ->
      :proceed = Idempotency.reserve(key)
      send(test_pid, :reserved)
      Process.sleep(:infinity)
    end)

    assert_receive :reserved
    assert Idempotency.reserve(key, wait_timeout: 50) == {:error, :timeout}
  end

  test "completing after the lease expired is reported, not cached" do
    key = unique_key()

    assert Idempotency.reserve(key, lease: 20) == :proceed
    Process.sleep(60)

    assert Idempotency.complete(key, :late) == {:error, :not_owner}
    assert Idempotency.reserve(key) == :proceed
  end

  test "stored results expire after their ttl" do
    key = unique_key()

    assert {:ok, :first} = Idempotency.run(key, fn -> :first end, ttl: 50)
    assert {:replay, :first} = Idempotency.run(key, fn -> :second end, ttl: 50)

    Process.sleep(80)

    assert {:ok, :second} = Idempotency.run(key, fn -> :second end, ttl: 50)
  end

  test "a fresh server re-checks the store before granting ownership" do
    # Simulates a caller that missed the store, then started a server
    # after the previous owner had already written its result.
    key = unique_key()
    id = {nil, key}
    :ok = Store.put(id, %{fingerprint: nil, result: :already_done}, 5_000)

    assert Throttlebeam.Keyed.call(Server, id, {:reserve, nil, 1_000}) ==
             {:replay, :already_done}
  end

  test "the sweep removes expired rows" do
    key = unique_key()
    :ok = Store.put({nil, key}, %{fingerprint: nil, result: :x}, 1)
    Process.sleep(5)

    assert Store.sweep() >= 1
    assert Store.fetch({nil, key}) == :miss
  end
end
