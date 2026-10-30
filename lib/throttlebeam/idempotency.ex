defmodule Throttlebeam.Idempotency do
  @moduledoc """
  Run an operation at most once per idempotency key.

  A client that retries a request, because a response was lost or a
  connection timed out, sends the same key again. The first request
  runs; every later request with that key, including ones that arrive
  while the first is still running, gets the first request's result.

      {:ok, charge} =
        Throttlebeam.Idempotency.run("order-123", fn -> Payments.charge(order) end)

  For HTTP APIs, `Throttlebeam.Plug.Idempotency` wraps this for you.

  ## Options

    * `:scope` - namespaces keys, for example by tenant, so two tenants
      using the same key never see each other's results. Default `nil`.
    * `:fingerprint` - any term describing the request. Reusing a key
      with a different fingerprint returns `{:error, :fingerprint_mismatch}`
      instead of replaying a result that belongs to another request.
      Default `nil`.
    * `:ttl` - how long a completed result is replayed, in ms.
      Default 24 hours.
    * `:lease` - how long the first request may hold the key before
      waiting callers give up, in ms. Set it above your slowest
      operation. Default 30 seconds.
    * `:wait_timeout` - how long a duplicate caller waits for the
      first request to finish, in ms. Default 30 seconds.
  """

  alias Throttlebeam.Idempotency.{Server, Store}
  alias Throttlebeam.Keyed

  require Logger

  @default_ttl :timer.hours(24)
  @default_lease :timer.seconds(30)
  @default_wait :timer.seconds(30)
  @max_takeovers 3

  @type reserve_result ::
          :proceed | {:replay, term()} | {:error, :fingerprint_mismatch | :timeout}

  @doc """
  Runs `fun` once for `key` and returns its result.

  Returns `{:ok, result}` when `fun` ran in this call, `{:replay, result}`
  when another call already produced the result, or `{:error, reason}`.
  If `fun` raises, the key is released so a retry can run it again,
  and the exception is re-raised.
  """
  @spec run(term(), (-> term()), keyword()) ::
          {:ok, term()} | {:replay, term()} | {:error, :fingerprint_mismatch | :timeout}
  def run(key, fun, opts \\ []) when is_function(fun, 0) do
    case reserve(key, opts) do
      :proceed ->
        result =
          try do
            fun.()
          catch
            kind, reason ->
              release(key, opts)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        case complete(key, result, opts) do
          :ok ->
            {:ok, result}

          {:error, :not_owner} ->
            Logger.warning(
              "Throttlebeam.Idempotency: lease expired before key #{inspect(key)} completed; result not cached"
            )

            {:ok, result}
        end

      other ->
        other
    end
  end

  @doc """
  Claims `key` for the calling process, or returns the existing result.

  Returns `:proceed` when the caller now owns the key and must later
  call `complete/3` or `release/2` from the same process. Duplicate
  callers block until the owner finishes.
  """
  @spec reserve(term(), keyword()) :: reserve_result()
  def reserve(key, opts \\ []) do
    id = id(key, opts)
    fingerprint = Keyword.get(opts, :fingerprint)

    # Fast path: a finished key is answered from ETS without touching
    # any process.
    case Store.fetch(id) do
      {:ok, entry} -> replay(entry, fingerprint)
      :miss -> reserve_in_flight(id, fingerprint, opts, @max_takeovers)
    end
  end

  @doc "Stores `result` for `key` and hands it to any waiting callers."
  @spec complete(term(), term(), keyword()) :: :ok | {:error, :not_owner}
  def complete(key, result, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    Keyed.call(Server, id(key, opts), {:complete, result, ttl})
  end

  @doc """
  Gives up ownership of `key` without storing a result.

  Use this when the operation failed in a way a retry should be allowed
  to fix. One of the waiting callers, if any, takes over.
  """
  @spec release(term(), keyword()) :: :ok | {:error, :not_owner}
  def release(key, opts \\ []) do
    Keyed.call(Server, id(key, opts), :release)
  end

  @doc false
  def replay(%{fingerprint: fingerprint, result: result}, fingerprint), do: {:replay, result}
  def replay(_entry, _fingerprint), do: {:error, :fingerprint_mismatch}

  defp reserve_in_flight(_id, _fingerprint, _opts, 0), do: {:error, :timeout}

  defp reserve_in_flight(id, fingerprint, opts, takeovers_left) do
    lease = Keyword.get(opts, :lease, @default_lease)

    call_opts = [
      timeout: Keyword.get(opts, :wait_timeout, @default_wait),
      # The server we reached stopped before serving us. Most often the
      # owner just completed, so the result is already in the store and
      # no new server is needed.
      before_retry: fn ->
        case Store.fetch(id) do
          {:ok, entry} -> {:halt, replay(entry, fingerprint)}
          :miss -> :retry
        end
      end
    ]

    case Keyed.call(Server, id, {:reserve, fingerprint, lease}, call_opts) do
      # The owner died before finishing. Try to take the key over.
      :released -> reserve_in_flight(id, fingerprint, opts, takeovers_left - 1)
      reply -> reply
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  defp id(key, opts), do: {Keyword.get(opts, :scope), key}
end
