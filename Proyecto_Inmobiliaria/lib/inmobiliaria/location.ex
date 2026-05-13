defmodule Inmobiliaria.Location do
  @moduledoc """
  Validación y gestión de ubicaciones válidas del sistema.
  Las ubicaciones se leen desde data/locations.dat.
  """

  @locations_file "data/locations.dat"

  def load_locations do
    case File.read(@locations_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _} ->
        []
    end
  end

  def valid?(ubicacion) do
    locations = load_locations()

    match =
      Enum.find(locations, fn loc ->
        String.downcase(loc) == String.downcase(ubicacion)
      end)

    case match do
      nil -> {:error, "Ubicación '#{ubicacion}' no válida."}
      loc -> {:ok, loc}
    end
  end

  def list_locations do
    case load_locations() do
      [] -> {:error, "No hay ubicaciones registradas."}
      locs -> {:ok, locs}
    end
  end

  def add_location(ubicacion) do
    ubicacion = String.trim(ubicacion)
    locations = load_locations()

    already_exists =
      Enum.any?(locations, fn loc ->
        String.downcase(loc) == String.downcase(ubicacion)
      end)

    if already_exists do
      {:error, "La ubicación '#{ubicacion}' ya existe."}
    else
      File.write(@locations_file, ubicacion <> "\n", [:append])
      {:ok, ubicacion}
    end
  end
end
