defmodule Throttlebeam.Idempotency.Store do
  @moduledoc """
  Holds completed idempotent results until they expire.

  Finished results live in a public ETS table rather than in a process
  per key. A 24 hour window at a few hundred requests per second would
  otherwise mean millions of idle processes, past the VM's default
  process limit. Processes only exist while a request is in flight;
  see `Throttlebeam.Idempotency.Server`.

  Expiry is checked on every read, so an expired entry is never served.
  A periodic sweep deletes expired rows to reclaim memory.

  The table is owned by this process. If it crashes, cached results are
  lost and the next request for each key runs again, which is the same
  outcome as the entry expiring early.
  """
  use GenServer

  @table __MODULE__
  @default_sweep_interval :timer.seconds(60)

  @type entry :: %{fingerprint: term(), result: term()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the live entry for `id`, or `:miss` if absent or expired."
  @spec fetch(term()) :: {:ok, entry()} | :miss
  def fetch(id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, id) do
      [{^id, entry, expires_at}] when expires_at > now -> {:ok, entry}
      _ -> :miss
    end
  end

  @doc "Stores `entry` under `id` for `ttl_ms` milliseconds."
  @spec put(term(), entry(), non_neg_integer()) :: :ok
  def put(id, entry, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    true = :ets.insert(@table, {id, entry, expires_at})
    :ok
  end

  @doc "Deletes expired rows now. Returns how many were removed."
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)
    schedule_sweep(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, %{interval: interval} = state) do
    sweep()
    schedule_sweep(interval)
    {:noreply, state}
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)
end
