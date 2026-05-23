defmodule Inmobiliaria.Application do
  use Application

  @moduledoc """
  Punto de entrada OTP. Arranca el árbol de supervisión:

    Inmobiliaria.MainSupervisor
    ├── Inmobiliaria.Supervisor       (DynamicSupervisor — gestiona procesos de propiedades)
    ├── Inmobiliaria.UserManager      (GenServer — usuarios y puntajes, persiste en users.json)
    ├── Inmobiliaria.PropertyManager  (GenServer — registro de propiedades, persiste en properties.json)
    └── Inmobiliaria.MessageManager   (GenServer — mensajería en tiempo real, persiste en messages.json)
  """

  @impl true
  def start(_type, _args) do
    children = [
      {Inmobiliaria.Supervisor, []},
      {Inmobiliaria.UserManager, []},
      {Inmobiliaria.PropertyManager, []},
      {Inmobiliaria.MessageManager, []}
    ]

    opts = [strategy: :one_for_one, name: Inmobiliaria.MainSupervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Al arrancar, levantamos un proceso GenServer por cada propiedad
    # que estaba persistida en JSON. Así el árbol OTP queda completo.
    restore_property_processes()

    {:ok, pid}
  end

  def start_cli do
    Inmobiliaria.Server.start()
  end

  defp restore_property_processes do
    case Inmobiliaria.PropertyManager.list_all() do
      {:ok, props} ->
        Enum.each(props, fn prop ->
          case Inmobiliaria.Supervisor.start_property(prop) do
            {:ok, _}                        -> :ok
            {:error, {:already_started, _}} -> :ok
            _                               -> :ok
          end
        end)
      _ ->
        :ok
    end
  end
end
