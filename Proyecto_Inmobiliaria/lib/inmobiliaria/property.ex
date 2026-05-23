defmodule Inmobiliaria.Property do
  use GenServer

  @moduledoc """
  GenServer que representa una propiedad individual en el sistema.
  Cada propiedad publicada corre como un proceso independiente,
  permitiendo manejar operaciones concurrentes sin afectar las demás.

  Estados posibles: "disponible" | "reservada" | "vendida" | "arrendada"
  """

  # Una reserva dura 30 minutos
  @tiempo_reserva_ms 30 * 60 * 1000

  # ---- API PÚBLICA ----

  def start_link(property_data) do
    GenServer.start_link(__MODULE__, property_data, name: String.to_atom(property_data.id))
  end

  def get(id, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, :get)

  def buy(id, cliente, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, {:buy, cliente})

  def rent(id, cliente, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, {:rent, cliente})

  def update(id, campos, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, {:update, campos})

  def reserve(id, cliente, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, {:reserve, cliente})

  def cancel_reservation(id, cliente, node \\ node()),
    do: GenServer.call({String.to_atom(id), node}, {:cancel_reservation, cliente})

  # ---- CALLBACKS ----

  @impl true
  def init(data) do
    # Garantizamos que todas las claves opcionales existan desde el inicio.
    # Esto es necesario porque %{map | key: val} solo funciona con claves ya presentes.
    state =
      data
      |> Map.put_new(:timer_ref, nil)
      |> Map.put_new(:cliente, nil)
      |> Map.put_new(:reservado_por, nil)
      |> Map.put_new(:reservado_hasta, nil)

    # Si se reinicia con una reserva activa (el timer ya no existe), la limpiamos.
    state =
      if state.estado == "reservada" do
        %{state | estado: "disponible", reservado_por: nil, reservado_hasta: nil}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:buy, cliente}, _from, state) do
    case state.estado do
      "disponible" ->
        nuevo = %{state | estado: "vendida", cliente: cliente}
        {:reply, {:ok, nuevo}, nuevo}

      # El mismo usuario que reservó puede proceder a comprar directamente
      "reservada" when state.reservado_por == cliente ->
        cancelar_timer(state.timer_ref)
        nuevo = %{state | estado: "vendida", cliente: cliente,
                          reservado_por: nil, reservado_hasta: nil, timer_ref: nil}
        {:reply, {:ok, nuevo}, nuevo}

      "reservada" ->
        {:reply, {:error, "Propiedad reservada por '#{state.reservado_por}'. No disponible."}, state}

      otro ->
        {:reply, {:error, "Propiedad no disponible. Estado actual: #{otro}"}, state}
    end
  end

  @impl true
  def handle_call({:rent, cliente}, _from, state) do
    case state.estado do
      "disponible" ->
        nuevo = %{state | estado: "arrendada", cliente: cliente}
        {:reply, {:ok, nuevo}, nuevo}

      # El mismo usuario que reservó puede proceder a arrendar directamente
      "reservada" when state.reservado_por == cliente ->
        cancelar_timer(state.timer_ref)
        nuevo = %{state | estado: "arrendada", cliente: cliente,
                          reservado_por: nil, reservado_hasta: nil, timer_ref: nil}
        {:reply, {:ok, nuevo}, nuevo}

      "reservada" ->
        {:reply, {:error, "Propiedad reservada por '#{state.reservado_por}'. No disponible."}, state}

      otro ->
        {:reply, {:error, "Propiedad no disponible. Estado actual: #{otro}"}, state}
    end
  end

  @impl true
  def handle_call({:update, campos}, _from, state) do
    nuevo = Map.merge(state, campos)
    {:reply, {:ok, nuevo}, nuevo}
  end

  @impl true
  def handle_call({:reserve, cliente}, _from, state) do
    case state.estado do
      "disponible" ->
        # Programamos el vencimiento automático de la reserva
        timer_ref = Process.send_after(self(), :expire_reservation, @tiempo_reserva_ms)
        expira = DateTime.utc_now() |> DateTime.add(30, :minute) |> DateTime.to_string()

        nuevo = %{state |
          estado: "reservada",
          reservado_por: cliente,
          reservado_hasta: expira,
          timer_ref: timer_ref
        }
        {:reply, {:ok, nuevo}, nuevo}

      "reservada" ->
        {:reply, {:error, "La propiedad ya está reservada por '#{state.reservado_por}'."}, state}

      otro ->
        {:reply, {:error, "Propiedad no disponible para reservar. Estado: #{otro}"}, state}
    end
  end

  @impl true
  def handle_call({:cancel_reservation, cliente}, _from, state) do
    cond do
      state.estado != "reservada" ->
        {:reply, {:error, "Esta propiedad no tiene una reserva activa."}, state}

      state.reservado_por != cliente ->
        {:reply, {:error, "Solo '#{state.reservado_por}' puede cancelar esta reserva."}, state}

      true ->
        cancelar_timer(state.timer_ref)
        nuevo = %{state | estado: "disponible", reservado_por: nil,
                          reservado_hasta: nil, timer_ref: nil}
        {:reply, {:ok, nuevo}, nuevo}
    end
  end

  # Mensaje interno que llega cuando el temporizador de reserva expira
  @impl true
  def handle_info(:expire_reservation, state) do
    IO.puts("""

    [SISTEMA] La reserva de la propiedad #{state.id} ha expirado.
    La propiedad vuelve a estar disponible para todos.
    """)

    # Sincronizamos el estado con PropertyManager (que persiste en JSON)
    Inmobiliaria.PropertyManager.update_estado(state.id, "disponible")

    nuevo = %{state | estado: "disponible", reservado_por: nil,
                      reservado_hasta: nil, timer_ref: nil}
    {:noreply, nuevo}
  end

  # ---- PRIVADO ----

  defp cancelar_timer(nil), do: :ok
  defp cancelar_timer(ref), do: Process.cancel_timer(ref)
end
