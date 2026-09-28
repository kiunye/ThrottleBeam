defmodule Throttlebeam.KeyServer do
  @moduledoc """
  A short lived, per-key process handling either a debounce timer
  or a throttle window. Stops itself once its job is done, it is
  not meant to be a long running process.
  """
  use GenServer, restart: :temporary

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, %{}, name: via(key))
  end

  def via(key) do
    {:via, Registry, {Throttlebeam.Registry, key}}
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  # Debounce: every call resets the timer. The function only runs
  # once the quiet period actually elapses without another call.
  @impl true
  def handle_cast({:debounce, fun, delay}, state) do
    if timer = Map.get(state, :timer_ref) do
      Process.cancel_timer(timer)
    end

    ref = Process.send_after(self(), {:run_debounced, fun}, delay)
    {:noreply, Map.put(state, :timer_ref, ref)}
  end

  @impl true
  def handle_info({:run_debounced, fun}, state) do
    fun.()
    {:stop, :normal, state}
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

  @impl true
  def handle_info(:window_expired, state) do
    {:stop, :normal, state}
  end
end
