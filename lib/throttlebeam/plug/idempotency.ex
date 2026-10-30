if Code.ensure_loaded?(Plug.Conn) do
  defmodule Throttlebeam.Plug.Idempotency do
    @moduledoc """
    Plug middleware for the `Idempotency-Key` header.

    The first request carrying a key runs normally and its response is
    stored. A repeat of that request, including one that arrives while
    the first is still running, gets the stored response back with an
    `idempotent-replayed: true` header and the handler does not run.

        plug Plug.Parsers, parsers: [:json], json_decoder: Jason
        plug Throttlebeam.Plug.Idempotency, scope: &MyApp.tenant_id/1
        plug :match
        plug :dispatch

    Place it after `Plug.Parsers` so the parsed body is part of the
    request fingerprint, and before `:match` so a replay skips routing.

    ## Responses

      * Reusing a key with a different method, path, query or body
        returns `422` instead of someone else's response.
      * A duplicate that waits longer than `:wait_timeout`, or whose
        original outlives its `:lease`, returns `409`.
      * A key longer than 255 bytes, or more than one key header,
        returns `400`.
      * `5xx` responses are not stored. The key is released so the
        client's retry runs the handler again.

    ## Options

      * `:methods` - methods to guard. Default `["POST", "PATCH"]`.
      * `:header` - request header to read. Default `"idempotency-key"`.
      * `:scope` - `fn conn -> term end` used to namespace keys, for
        example by tenant. Default: no scope.
      * `:ttl`, `:lease`, `:wait_timeout` - see `Throttlebeam.Idempotency`.
    """
    @behaviour Plug

    import Plug.Conn

    alias Throttlebeam.Idempotency

    @replayed_headers ["content-type"]
    @max_key_bytes 255

    @impl true
    def init(opts) do
      %{
        methods: Keyword.get(opts, :methods, ["POST", "PATCH"]),
        header: Keyword.get(opts, :header, "idempotency-key"),
        scope: Keyword.get(opts, :scope),
        idempotency_opts: Keyword.take(opts, [:ttl, :lease, :wait_timeout])
      }
    end

    @impl true
    def call(%Plug.Conn{method: method} = conn, %{methods: methods} = config) do
      if method in methods do
        case get_req_header(conn, config.header) do
          [] -> conn
          [key] when byte_size(key) in 1..@max_key_bytes -> guard(conn, key, config)
          _ -> error(conn, 400, "invalid_idempotency_key")
        end
      else
        conn
      end
    end

    defp guard(conn, key, config) do
      opts =
        [scope: scope(conn, config), fingerprint: fingerprint(conn)] ++ config.idempotency_opts

      case Idempotency.reserve(key, opts) do
        :proceed -> register_before_send(conn, &finish(&1, key, opts))
        {:replay, response} -> replay(conn, response)
        {:error, :fingerprint_mismatch} -> error(conn, 422, "idempotency_key_reused")
        {:error, :timeout} -> error(conn, 409, "idempotency_key_in_progress")
      end
    end

    # Runs in the request process just before the response is sent,
    # after every downstream plug and the handler have finished.
    defp finish(conn, key, opts) do
      if conn.state == :set and conn.status < 500 do
        response = %{
          status: conn.status,
          headers: Enum.filter(conn.resp_headers, fn {name, _} -> name in @replayed_headers end),
          body: IO.iodata_to_binary(conn.resp_body)
        }

        Idempotency.complete(key, response, opts)
      else
        # Server errors, chunked and file responses: let a retry run again.
        Idempotency.release(key, opts)
      end

      conn
    end

    defp replay(conn, %{status: status, headers: headers, body: body}) do
      headers
      |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
      |> put_resp_header("idempotent-replayed", "true")
      |> send_resp(status, body)
      |> halt()
    end

    defp error(conn, status, code) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, ~s({"error":"#{code}"}))
      |> halt()
    end

    defp scope(_conn, %{scope: nil}), do: nil
    defp scope(conn, %{scope: fun}) when is_function(fun, 1), do: fun.(conn)

    defp fingerprint(conn) do
      body =
        case conn.body_params do
          %Plug.Conn.Unfetched{} -> nil
          params -> params
        end

      term = {conn.method, conn.request_path, conn.query_string, body}
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    end
  end
end
