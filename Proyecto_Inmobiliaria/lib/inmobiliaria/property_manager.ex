defmodule Inmobiliaria.PropertyManager do
  use GenServer

  @moduledoc """
  Registro, consulta y filtrado de propiedades.
  Corre como GenServer para serializar escrituras y evitar condiciones de carrera.
  Persiste datos en formato JSON (data/properties.json).

  Campos de cada propiedad:
    id, tipo, modalidad, ubicacion, precio, habitaciones, area,
    banios, parking, amoblado, descripcion,  <- campos de descripción detallada
    estado, propietario
  """

  @properties_file "data/properties.json"
  @valid_roles ["vendedor", "arrendador"]

  # ---- ARRANQUE ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ---- API PÚBLICA ----

  def publish(propietario, rol, tipo, modalidad, ubicacion, precio,
              habitaciones, area, banios, parking, amoblado, descripcion, node \\ node()) do
    GenServer.call({__MODULE__, node},
      {:publish, propietario, rol, tipo, modalidad, ubicacion, precio,
       habitaciones, area, banios, parking, amoblado, descripcion})
  end

  def list_all(node \\ node()),                   do: GenServer.call({__MODULE__, node}, :list_all)
  def filter(filters, node \\ node()),            do: GenServer.call({__MODULE__, node}, {:filter, filters})
  def get(id, node \\ node()),                    do: GenServer.call({__MODULE__, node}, {:get, id})
  def update_estado(id, nuevo_estado, node \\ node()),
    do: GenServer.call({__MODULE__, node}, {:update_estado, id, nuevo_estado})

  # ---- CALLBACKS GENSERVER ----

  @impl true
  def init(:ok) do
    {:ok, load_properties()}
  end

  @impl true
  def handle_call({:publish, propietario, rol, tipo, modalidad, ubicacion, precio,
                   habitaciones, area, banios, parking, amoblado, descripcion}, _from, props) do
    cond do
      rol not in @valid_roles ->
        {:reply, {:error, "Solo vendedores y arrendadores pueden publicar propiedades."}, props}

      is_nil(tipo) or is_nil(modalidad) or is_nil(ubicacion) or
      is_nil(precio) or is_nil(habitaciones) or is_nil(area) ->
        {:reply, {:error, "Faltan parámetros obligatorios: tipo, modalidad, ubicacion, precio, habitaciones, area"}, props}

      true ->
        case Inmobiliaria.Location.valid?(ubicacion) do
          {:error, msg} ->
            {:reply, {:error, msg}, props}

          {:ok, ubicacion_valida} ->
            id = generar_id(props)
            propiedad = %{
              id:          id,
              tipo:        tipo,
              modalidad:   modalidad,
              ubicacion:   ubicacion_valida,
              precio:      precio,
              habitaciones: habitaciones,
              area:        area,
              banios:      banios || 1,
              parking:     parking || false,
              amoblado:    amoblado || false,
              descripcion: descripcion || "",
              estado:      "disponible",
              propietario: propietario
            }
            nuevas = [propiedad | props]
            save_properties(nuevas)
            Inmobiliaria.Supervisor.start_property(propiedad)
            {:reply, {:ok, propiedad}, nuevas}
        end
    end
  end

  @impl true
  def handle_call(:list_all, _from, props) do
    case props do
      [] -> {:reply, {:error, "No hay propiedades registradas."}, props}
      _  -> {:reply, {:ok, props}, props}
    end
  end

  @impl true
  def handle_call({:filter, filtros}, _from, props) do
    tipo       = Keyword.get(filtros, :tipo)
    modalidad  = Keyword.get(filtros, :modalidad)
    ubicacion  = Keyword.get(filtros, :ubicacion)
    precio_min = Keyword.get(filtros, :precio_min)
    precio_max = Keyword.get(filtros, :precio_max)

    filtradas =
      props
      |> Enum.filter(fn p -> p.estado == "disponible" end)
      |> Enum.filter(fn p -> if tipo,       do: p.tipo == tipo,                                       else: true end)
      |> Enum.filter(fn p -> if modalidad,  do: p.modalidad == modalidad,                             else: true end)
      |> Enum.filter(fn p -> if ubicacion,  do: String.downcase(p.ubicacion) == String.downcase(ubicacion), else: true end)
      |> Enum.filter(fn p -> if precio_min, do: p.precio >= precio_min,                               else: true end)
      |> Enum.filter(fn p -> if precio_max, do: p.precio <= precio_max,                               else: true end)

    case filtradas do
      [] -> {:reply, {:error, "No se encontraron propiedades con esos filtros."}, props}
      _  -> {:reply, {:ok, filtradas}, props}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, props) do
    case Enum.find(props, fn p -> p.id == id end) do
      nil  -> {:reply, {:error, "Propiedad '#{id}' no encontrada."}, props}
      prop -> {:reply, {:ok, prop}, props}
    end
  end

  @impl true
  def handle_call({:update_estado, id, nuevo_estado}, _from, props) do
    updated = Enum.map(props, fn p ->
      if p.id == id do
        p = Map.put(p, :estado, nuevo_estado)
        # Al volver a disponible, limpiamos datos de reserva
        if nuevo_estado == "disponible" do
          Map.merge(p, %{reservado_por: nil, reservado_hasta: nil})
        else
          p
        end
      else
        p
      end
    end)
    save_properties(updated)
    {:reply, {:ok, nuevo_estado}, updated}
  end

  # ---- PERSISTENCIA JSON ----

  defp load_properties do
    case File.read(@properties_file) do
      {:ok, content} ->
        content = String.trim(content)
        if content == "" do
          []
        else
          content
          |> JSON.decode!()
          |> Enum.map(&atomize_keys/1)
          |> Enum.map(&aplicar_defaults/1)
        end

      {:error, _} ->
        []
    end
  end

  defp save_properties(props) do
    # Las reservas son volátiles (solo viven en memoria).
    # Guardamos el estado como "disponible" si estaba "reservada"
    # para que al reiniciar no queden propiedades bloqueadas.
    serializable = Enum.map(props, fn p ->
      estado = if p.estado == "reservada", do: "disponible", else: p.estado
      p
      |> Map.drop([:timer_ref, :cliente, :reservado_por, :reservado_hasta])
      |> Map.put(:estado, estado)
    end)

    File.write(@properties_file, JSON.encode!(serializable))
  end

  # Convierte claves string (que devuelve JSON.decode!) a átomos
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # Agrega valores por defecto para campos nuevos en propiedades antiguas
  defp aplicar_defaults(p) do
    p
    |> Map.put_new(:banios, 1)
    |> Map.put_new(:parking, false)
    |> Map.put_new(:amoblado, false)
    |> Map.put_new(:descripcion, "")
  end

  defp generar_id([]), do: "prop001"
  defp generar_id(props) do
    max =
      props
      |> Enum.map(fn p -> p.id |> String.replace("prop", "") |> String.to_integer() end)
      |> Enum.max()
    "prop#{String.pad_leading(Integer.to_string(max + 1), 3, "0")}"
  end
end
