defmodule Throttlebeam.Keyed do
  @moduledoc false

  # Shared plumbing for the per-key servers.
  #
  # Every per-key server in this library stops itself once its job is
  # done, so a caller can look up a key that is still registered and
  # reach a process that exits before serving it. The server always
  # replies before it stops, so a call that saw `:noproc` or `:normal`
  # was never processed and is safe to retry on a fresh server.
  #
  # A stopping server stays registered until it has fully exited, so
  # retrying straight away can reach the same dying process again.
  # Before retrying we wait for that exact process to exit. Registry
  # replaces a dead entry on the next registration, so every retry is
  # guaranteed to reach a different server, and the cap below bounds
  # real attempts rather than spins.
  #
  # If the supervision tree is down, start_child exits immediately and
  # that exit propagates instead of being retried.

  @max_attempts 3

  @doc false
  # Options:
  #   * :timeout - GenServer.call timeout. Default 5_000.
  #   * :before_retry - zero-arity fun run after the dying server has
  #     exited and before retrying. Return {:halt, value} to answer the
  #     caller without starting another server, or :retry.
  @spec call(module(), term(), term(), keyword()) :: term()
  def call(server, key, message, opts \\ []) do
    attempt(server, key, message, opts, @max_attempts)
  end

  defp attempt(server, key, message, opts, attempts_left) do
    pid = ensure_started(server, key)

    try do
      GenServer.call(pid, message, Keyword.get(opts, :timeout, 5_000))
    catch
      :exit, {reason, _} when reason in [:noproc, :normal] and attempts_left > 1 ->
        await_exit(pid)

        case Keyword.get(opts, :before_retry, fn -> :retry end).() do
          {:halt, value} -> value
          :retry -> attempt(server, key, message, opts, attempts_left - 1)
        end
    end
  end

  # Another caller winning the start_child race registers the key
  # first, which is as good as having started it ourselves.
  defp ensure_started(server, key) do
    case DynamicSupervisor.start_child(Throttlebeam.DynamicSupervisor, {server, key: key}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end
end
