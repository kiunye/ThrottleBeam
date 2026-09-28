defmodule Throttlebeam.KeyServer do
  @moduledoc """
  A short lived, per-key process handling either a debounce timer
  or a throttle window. Stops itself once its job is done, it is
  not meant to be a long running process.

  Since the server stops itself, a request can race that
  shutdown: the key is still registered while the process is
  going away. `request/2` is the supported entry point for other
  modules, it retries on a fresh server when that happens.
  """
  use GenServer, restart: :temporary

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, %{}, name: via(key))
  end

  def via(key) do
    {:via, Registry, {Throttlebeam.Registry, key}}
  end

  @doc """
  Ensures a server for `key` exists, then delivers `request`.

  The per-key server stops itself once its job is done, so this
  can race that shutdown and reach a process that dies before
  serving us. The request was then never processed (the server
  replies before it can stop), so it is safe to start a fresh
  server and try again.
  """
  def request(key, request) do
    ensure_started(key)

    GenServer.call(via(key), request)
  catch
    :exit, :noproc -> request(key, request)
    :exit, {reason, _} when reason in [:noproc, :normal] -> request(key, request)
  end

  # Another caller winning the start_child race registers the key
  # first; that is as good as having started it ourselves.
  defp ensure_started(key) do
    case DynamicSupervisor.start_child(
           Throttlebeam.DynamicSupervisor,
           {__MODULE__, key: key}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  # Debounce: every call resets the timer. The function only runs
  # once the quiet period actually elapses without another call.
  @impl true
  def handle_call({:debounce, fun, delay}, _from, state) do
    if timer = Map.get(state, :timer_ref) do
      Process.cancel_timer(timer)
    end

    # cancel_timer/1 cannot reach a message already delivered to
    # our mailbox, so a timer that fired right before this call
    # could still run the fun early. Discard any stale run.
    drain_fired_timer()

    ref = Process.send_after(self(), {:run_debounced, fun}, delay)
    {:reply, :ok, Map.put(state, :timer_ref, ref)}
  end

  # Throttle: run immediately on the leading edge if we're not
  # already inside a window, otherwise reject the call outright.
  @impl true
  def handle_call({:throttle, fun, interval}, _from, state) do
    case Map.get(state, :window_active?) do
      true ->
        {:reply, :throttled, state}

      _ ->
        fun.()
        Process.send_after(self(), :window_expired, interval)
        {:reply, :executed, Map.put(state, :window_active?, true)}
    end
  end

  # Shutdown clauses: the debounced function has run after a full
  # quiet period, or the throttle window has expired. Either way
  # the server's job is done and it stops itself.
  @impl true
  def handle_info({:run_debounced, fun}, state) do
    fun.()
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:window_expired, state) do
    {:stop, :normal, state}
  end

  defp drain_fired_timer do
    receive do
      {:run_debounced, _fun} -> drain_fired_timer()
    after
      0 -> :ok
    end
  end
end
