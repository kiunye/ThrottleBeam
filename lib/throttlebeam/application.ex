defmodule Throttlebeam.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Throttlebeam.Registry},
      {DynamicSupervisor, name: Throttlebeam.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Throttlebeam.Supervisor)
  end
end
