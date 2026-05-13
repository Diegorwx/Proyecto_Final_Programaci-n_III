defmodule Inmobiliaria.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Inmobiliaria.PropertyRegistry},
      {Inmobiliaria.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Inmobiliaria.MainSupervisor]
    Supervisor.start_link(children, opts)
  end

  def start_cli do
    Inmobiliaria.Server.start()
  end
end
