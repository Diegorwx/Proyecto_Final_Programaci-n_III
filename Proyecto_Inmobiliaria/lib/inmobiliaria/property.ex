defmodule Inmobiliaria.Property do
  use GenServer

  @moduledoc """
  GenServer que representa una propiedad individual en el sistema.
  Cada propiedad publicada corre como un proceso independiente,
  permitiendo manejar operaciones concurrentes sin afectar las demás.
  """

  # ---- API PÚBLICA ----

  def start_link(property_data) do
    GenServer.start_link(__MODULE__, property_data, name: via(property_data.id))
  end

  def get(id) do
    GenServer.call(via(id), :get)
  end

  def buy(id, cliente) do
    GenServer.call(via(id), {:buy, cliente})
  end

  def rent(id, cliente) do
    GenServer.call(via(id), {:rent, cliente})
  end

  def update(id, campos) do
    GenServer.call(via(id), {:update, campos})
  end

  # ---- CALLBACKS ----

  @impl true
  def init(property_data) do
    {:ok, property_data}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:buy, cliente}, _from, state) do
    case state.estado do
      "disponible" ->
        nuevo_estado = Map.put(state, :estado, "vendida")
        nuevo_estado = Map.put(nuevo_estado, :cliente, cliente)
        {:reply, {:ok, nuevo_estado}, nuevo_estado}

      otro ->
        {:reply, {:error, "La propiedad no está disponible. Estado actual: #{otro}"}, state}
    end
  end

  @impl true
  def handle_call({:rent, cliente}, _from, state) do
    case state.estado do
      "disponible" ->
        nuevo_estado = Map.put(state, :estado, "arrendada")
        nuevo_estado = Map.put(nuevo_estado, :cliente, cliente)
        {:reply, {:ok, nuevo_estado}, nuevo_estado}

      otro ->
        {:reply, {:error, "La propiedad no está disponible. Estado actual: #{otro}"}, state}
    end
  end

  @impl true
  def handle_call({:update, campos}, _from, state) do
    nuevo_estado = Map.merge(state, campos)
    {:reply, {:ok, nuevo_estado}, nuevo_estado}
  end

  # ---- REGISTRO DE NOMBRE ----

  defp via(id) do
    {:via, Registry, {Inmobiliaria.PropertyRegistry, id}}
  end
end
