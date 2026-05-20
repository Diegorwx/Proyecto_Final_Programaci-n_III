defmodule Inmobiliaria.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Inmobiliaria.PropertyRegistry},
      {Inmobiliaria.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Inmobiliaria.MainSupervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    restore_properties()

    {:ok, pid}
  end

  def start_cli do
    Inmobiliaria.Server.start()
  end

  defp restore_properties do
    case File.read("data/properties.dat") do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case String.split(line, ";") do
            [id, tipo, modalidad, ubicacion, precio, habitaciones, area, estado, propietario] ->
              property = %{
                id: id,
                tipo: tipo,
                modalidad: modalidad,
                ubicacion: ubicacion,
                precio: String.to_integer(precio),
                habitaciones: String.to_integer(habitaciones),
                area: String.to_float(area),
                estado: estado,
                propietario: propietario
              }
              Inmobiliaria.Supervisor.start_property(property)
            _ ->
              :skip
          end
        end)

      {:error, _} ->
        :ok
    end
  end
end
