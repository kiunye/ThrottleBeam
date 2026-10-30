defmodule Throttlebeam.Idempotency.Server do
  @moduledoc """
  Coordinates one idempotency key while its first request is in flight.

  The first caller to reserve a key becomes its owner and is told to
  proceed. Callers that arrive while the owner is still working are
  parked, without a reply, until the owner finishes. When the owner
  completes, the result is written to `Throttlebeam.Idempotency.Store`,
  every parked caller gets that same result, and this process stops.

  The server monitors the owner. If the owner dies before completing,
  parked callers are told the key was released and one of them takes
  over. If the owner is still alive but holds the key longer than its
  lease, parked callers get `{:error, :timeout}` and the key is freed.
  """
  use GenServer, restart: :temporary

  alias Throttlebeam.Idempotency.Store

  def start_link(opts) do
    id = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, id, name: via(id))
  end

  def via(id) do
    {:via, Registry, {Throttlebeam.Registry, {Throttlebeam.Idempotency, id}}}
  end

  @impl true
  def init(id) do
    {:ok,
     %{id: id, status: :new, fingerprint: nil, owner: nil, monitor: nil, lease: nil, waiters: []}}
  end

  # A new server re-checks the store before granting ownership. The
  # previous owner writes its result before it unregisters, so a
  # caller that missed the store a moment ago and then started this
  # server will find the result here instead of running twice.
  @impl true
  def handle_call({:reserve, fingerprint, lease_ms}, {pid, _tag}, %{status: :new} = state) do
    case Store.fetch(state.id) do
      {:ok, entry} ->
        {:stop, :normal, Throttlebeam.Idempotency.replay(entry, fingerprint), state}

      :miss ->
        monitor = Process.monitor(pid)
        lease = Process.send_after(self(), :lease_expired, lease_ms)

        {:reply, :proceed,
         %{
           state
           | status: :pending,
             fingerprint: fingerprint,
             owner: pid,
             monitor: monitor,
             lease: lease
         }}
    end
  end

  def handle_call({:reserve, fingerprint, _lease}, from, %{status: :pending} = state) do
    if fingerprint == state.fingerprint do
      {:noreply, %{state | waiters: [from | state.waiters]}}
    else
      {:reply, {:error, :fingerprint_mismatch}, state}
    end
  end

  def handle_call(
        {:complete, result, ttl_ms},
        {pid, _tag},
        %{status: :pending, owner: pid} = state
      ) do
    :ok = Store.put(state.id, %{fingerprint: state.fingerprint, result: result}, ttl_ms)
    reply_waiters(state, {:replay, result})
    {:stop, :normal, :ok, state}
  end

  def handle_call(:release, {pid, _tag}, %{status: :pending, owner: pid} = state) do
    reply_waiters(state, :released)
    {:stop, :normal, :ok, state}
  end

  # complete/release from a process that does not own the key. On a
  # fresh server this means the owner's lease ran out and the key was
  # already freed, so there is nothing to coordinate: stop again.
  def handle_call(_message, _from, %{status: :new} = state) do
    {:stop, :normal, {:error, :not_owner}, state}
  end

  def handle_call(_message, _from, state) do
    {:reply, {:error, :not_owner}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    reply_waiters(state, :released)
    {:stop, :normal, state}
  end

  def handle_info(:lease_expired, %{status: :pending} = state) do
    reply_waiters(state, {:error, :timeout})
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reply_waiters(state, reply) do
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
  end
end
