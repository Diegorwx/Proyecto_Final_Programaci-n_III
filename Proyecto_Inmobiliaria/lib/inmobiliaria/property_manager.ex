defmodule Inmobiliaria.PropertyManager do
  @moduledoc """
  Registro, consulta y filtrado de propiedades.
  Se encarga de persistir en properties.dat y de
  arrancar los procesos de cada propiedad via el Supervisor.
  """

  @properties_file "data/properties.dat"

  # ---- PERSISTENCIA ----

  defp load_properties do
    case File.read(@properties_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_property/1)

      {:error, _} ->
        []
    end
  end

  defp parse_property(line) do
    [id, tipo, modalidad, ubicacion, precio, habitaciones, area, estado, propietario] =
      String.split(line, ";")

    %{
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
  end

  defp save_properties(properties) do
    content =
      properties
      |> Enum.map(fn p ->
        "#{p.id};#{p.tipo};#{p.modalidad};#{p.ubicacion};#{p.precio};#{p.habitaciones};#{p.area};#{p.estado};#{p.propietario}"
      end)
      |> Enum.join("\n")

    File.write(@properties_file, content <> "\n")
  end

  defp generate_id(properties) do
    case properties do
      [] ->
        "prop001"

      _ ->
        max =
          properties
          |> Enum.map(fn p ->
            p.id |> String.replace("prop", "") |> String.to_integer()
          end)
          |> Enum.max()

        "prop#{String.pad_leading(Integer.to_string(max + 1), 3, "0")}"
    end
  end

  # ---- API PÚBLICA ----

  @doc """
  Publica una nueva propiedad y arranca su proceso GenServer.
  Solo vendedores y arrendadores pueden publicar.
  Retorna {:ok, property} o {:error, mensaje}.
  """
  def publish(propietario, rol, tipo, modalidad, ubicacion, precio, habitaciones, area) do
  valid_roles = ["vendedor", "arrendador"]

  cond do
    rol not in valid_roles ->
      {:error, "Solo vendedores y arrendadores pueden publicar propiedades."}

    is_nil(tipo) or is_nil(modalidad) or is_nil(ubicacion) or is_nil(precio) or is_nil(habitaciones) or is_nil(area) ->
      {:error, "Faltan parámetros. Uso: publish_property tipo=<tipo> modalidad=<modalidad> ubicacion=<ubicacion> precio=<precio> habitaciones=<num> area=<num>"}

    true ->
      case Inmobiliaria.Location.valid?(ubicacion) do
        {:error, msg} ->
          {:error, msg}

        {:ok, ubicacion_valida} ->
          properties = load_properties()
          id = generate_id(properties)

          property = %{
            id: id,
            tipo: tipo,
            modalidad: modalidad,
            ubicacion: ubicacion_valida,
            precio: precio,
            habitaciones: habitaciones,
            area: area,
            estado: "disponible",
            propietario: propietario
          }

          save_properties([property | properties])
          Inmobiliaria.Supervisor.start_property(property)
          {:ok, property}
      end
  end
end

  @doc """
  Lista todas las propiedades disponibles.
  """
  def list_all do
    case load_properties() do
      [] -> {:error, "No hay propiedades registradas."}
      props -> {:ok, props}
    end
  end

  @doc """
  Filtra propiedades según criterios opcionales.
  Todos los parámetros son opcionales, pasar nil para ignorar.
  """
  def filter(tipo: tipo, modalidad: modalidad, ubicacion: ubicacion, precio_min: precio_min, precio_max: precio_max) do
    properties = load_properties()

    filtered =
      properties
      |> Enum.filter(fn p -> p.estado == "disponible" end)
      |> Enum.filter(fn p -> if tipo, do: p.tipo == tipo, else: true end)
      |> Enum.filter(fn p -> if modalidad, do: p.modalidad == modalidad, else: true end)
      |> Enum.filter(fn p -> if ubicacion, do: String.downcase(p.ubicacion) == String.downcase(ubicacion), else: true end)
      |> Enum.filter(fn p -> if precio_min, do: p.precio >= precio_min, else: true end)
      |> Enum.filter(fn p -> if precio_max, do: p.precio <= precio_max, else: true end)

    case filtered do
      [] -> {:error, "No se encontraron propiedades con esos filtros."}
      props -> {:ok, props}
    end
  end

  @doc """
  Busca una propiedad por su id.
  """
  def get(id) do
    properties = load_properties()

    case Enum.find(properties, fn p -> p.id == id end) do
      nil -> {:error, "Propiedad '#{id}' no encontrada."}
      prop -> {:ok, prop}
    end
  end

  @doc """
  Actualiza el estado de una propiedad en el archivo.
  """
  def update_estado(id, nuevo_estado) do
    properties = load_properties()

    updated =
      Enum.map(properties, fn p ->
        if p.id == id do
          Map.put(p, :estado, nuevo_estado)
        else
          p
        end
      end)

    save_properties(updated)
    {:ok, nuevo_estado}
  end
end
