defmodule Throttlebeam.Plug.IdempotencyTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  defmodule Router do
    use Plug.Router

    plug Plug.Parsers, parsers: [:urlencoded]
    plug Throttlebeam.Plug.Idempotency, scope: &__MODULE__.tenant/1
    plug :match
    plug :dispatch

    def tenant(conn), do: conn |> get_req_header("x-tenant") |> List.first()

    post "/charges" do
      counter = conn.private[:counter]
      Process.sleep(String.to_integer(conn.params["delay"] || "0"))
      n = :counters.add(counter, 1, 1) && :counters.get(counter, 1)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, ~s({"charge":#{n}}))
    end

    post "/flaky" do
      send_resp(conn, 503, "try again")
    end
  end

  defp request(key, counter, opts \\ []) do
    body = Keyword.get(opts, :body, "amount=100")
    path = Keyword.get(opts, :path, "/charges")

    conn(:post, path, body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> then(fn conn -> if key, do: put_req_header(conn, "idempotency-key", key), else: conn end)
    |> then(fn conn ->
      case opts[:tenant] do
        nil -> conn
        tenant -> put_req_header(conn, "x-tenant", tenant)
      end
    end)
    |> put_private(:counter, counter)
    |> Router.call(Router.init([]))
  end

  defp key, do: "plug-#{System.unique_integer([:positive])}"

  test "requests without a key pass through every time" do
    counter = :counters.new(1, [])

    assert request(nil, counter).resp_body == ~s({"charge":1})
    assert request(nil, counter).resp_body == ~s({"charge":2})
  end

  test "a repeated key replays status, body and content type" do
    counter = :counters.new(1, [])
    key = key()

    first = request(key, counter)
    second = request(key, counter)

    assert first.status == 201
    assert second.status == 201
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "content-type") == get_resp_header(first, "content-type")
    assert get_resp_header(second, "idempotent-replayed") == ["true"]
    assert second.halted
    assert :counters.get(counter, 1) == 1
  end

  test "concurrent duplicates run the handler once" do
    counter = :counters.new(1, [])
    key = key()

    bodies =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn -> request(key, counter, body: "amount=100&delay=50").resp_body end)
      end)
      |> Task.await_many(2_000)

    assert Enum.uniq(bodies) == [~s({"charge":1})]
    assert :counters.get(counter, 1) == 1
  end

  test "reusing a key with a different body returns 422" do
    counter = :counters.new(1, [])
    key = key()

    assert request(key, counter, body: "amount=100").status == 201

    conn = request(key, counter, body: "amount=999")
    assert conn.status == 422
    assert conn.resp_body =~ "idempotency_key_reused"
    assert :counters.get(counter, 1) == 1
  end

  test "the same key under different tenants runs separately" do
    counter = :counters.new(1, [])
    key = key()

    assert request(key, counter, tenant: "acme").resp_body == ~s({"charge":1})
    assert request(key, counter, tenant: "globex").resp_body == ~s({"charge":2})
    assert request(key, counter, tenant: "acme").resp_body == ~s({"charge":1})
  end

  test "server errors are not stored, so a retry runs again" do
    counter = :counters.new(1, [])
    key = key()

    first = request(key, counter, path: "/flaky")
    second = request(key, counter, path: "/flaky")

    assert first.status == 503
    assert second.status == 503
    assert get_resp_header(second, "idempotent-replayed") == []
  end

  test "a key over 255 bytes is rejected" do
    counter = :counters.new(1, [])
    conn = request(String.duplicate("k", 256), counter)

    assert conn.status == 400
    assert :counters.get(counter, 1) == 0
  end

  test "GET requests are not guarded by default" do
    conn = conn(:get, "/anything") |> put_req_header("idempotency-key", key())
    config = Throttlebeam.Plug.Idempotency.init([])

    assert Throttlebeam.Plug.Idempotency.call(conn, config) == conn
  end
end
