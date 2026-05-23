defmodule Inmobiliaria.MessageManager do
  use GenServer

  @moduledoc """
  Gestión de mensajes entre clientes y propietarios.
  Corre como GenServer para soportar notificaciones en tiempo real.
  Persiste mensajes en formato JSON (data/messages.json).

  La característica de tiempo real funciona así:
  - Al conectarse, cada usuario registra su PID con register_session/3.
  - Al enviar un mensaje, si el destinatario está conectado (tiene PID registrado),
    se le envía una notificación directa: send(pid, {:new_message, msg}).
  - El loop del CLI (server.ex) revisa el buzón tras cada comando y muestra
    los mensajes nuevos en pantalla.
  """

  @messages_file "data/messages.json"

  # ---- ARRANQUE ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ---- API PÚBLICA ----

  # Registra el PID del proceso CLI del usuario para recibir notificaciones
  def register_session(username, pid, node \\ node()) do
    GenServer.cast({__MODULE__, node}, {:register, username, pid})
  end

  # Limpia el PID al desconectarse
  def unregister_session(username, node \\ node()) do
    GenServer.cast({__MODULE__, node}, {:unregister, username})
  end

  # El cliente envía un mensaje al propietario de una propiedad
  def send_message(de, propiedad_id, mensaje, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:send_message, de, propiedad_id, mensaje})
  end

  # El propietario responde a un cliente específico (chat bidireccional)
  def reply_message(de, propiedad_id, para, mensaje, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:reply_message, de, propiedad_id, para, mensaje})
  end

  # Mensajes recibidos por un usuario (donde él es el destinatario)
  def get_messages_for(para, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:get_messages_for, para})
  end

  # Todos los mensajes de una propiedad (ida y vuelta)
  def get_messages_by_property(propiedad_id, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:get_messages_by_property, propiedad_id})
  end

  # ---- CALLBACKS GENSERVER ----

  @impl true
  def init(:ok) do
    state = %{
      messages: load_messages(),
      online: %{}          # %{username => pid}
    }
    {:ok, state}
  end

  @impl true
  def handle_cast({:register, username, pid}, state) do
    {:noreply, %{state | online: Map.put(state.online, username, pid)}}
  end

  @impl true
  def handle_cast({:unregister, username}, state) do
    {:noreply, %{state | online: Map.delete(state.online, username)}}
  end

  @impl true
  def handle_call({:send_message, de, propiedad_id, mensaje}, _from, state) do
    case Inmobiliaria.PropertyManager.get(propiedad_id) do
      {:error, msg} ->
        {:reply, {:error, msg}, state}

      {:ok, propiedad} ->
        msg = %{
          fecha:        Date.utc_today() |> Date.to_string(),
          de:           de,
          para:         propiedad.propietario,
          propiedad_id: propiedad_id,
          mensaje:      mensaje
        }

        new_messages = [msg | state.messages]
        save_messages(new_messages)

        # Notificación en tiempo real si el destinatario está conectado
        notificar_si_online(state.online, propiedad.propietario, msg)

        {:reply, {:ok, msg}, %{state | messages: new_messages}}
    end
  end

  @impl true
  def handle_call({:reply_message, de, propiedad_id, para, mensaje}, _from, state) do
    # Verificamos que el remitente sea el propietario de la propiedad
    case Inmobiliaria.PropertyManager.get(propiedad_id) do
      {:error, msg} ->
        {:reply, {:error, msg}, state}

      {:ok, propiedad} ->
        if propiedad.propietario != de do
          {:reply, {:error, "Solo el propietario puede responder mensajes de esta propiedad."}, state}
        else
          msg = %{
            fecha:        Date.utc_today() |> Date.to_string(),
            de:           de,
            para:         para,
            propiedad_id: propiedad_id,
            mensaje:      mensaje
          }

          new_messages = [msg | state.messages]
          save_messages(new_messages)

          # Notificación en tiempo real al cliente
          notificar_si_online(state.online, para, msg)

          {:reply, {:ok, msg}, %{state | messages: new_messages}}
        end
    end
  end

  @impl true
  def handle_call({:get_messages_for, para}, _from, state) do
    # Siempre releemos del JSON para ver mensajes enviados desde otras sesiones
    mensajes_actuales = load_messages()
    filtrados = Enum.filter(mensajes_actuales, fn m -> m.para == para end)

    case filtrados do
      [] -> {:reply, {:error, "No tienes mensajes recibidos."}, %{state | messages: mensajes_actuales}}
      _  -> {:reply, {:ok, filtrados}, %{state | messages: mensajes_actuales}}
    end
  end

  @impl true
  def handle_call({:get_messages_by_property, propiedad_id}, _from, state) do
    # Siempre releemos del JSON para ver mensajes enviados desde otras sesiones
    mensajes_actuales = load_messages()
    filtrados = Enum.filter(mensajes_actuales, fn m -> m.propiedad_id == propiedad_id end)

    case filtrados do
      [] -> {:reply, {:error, "No hay mensajes para la propiedad '#{propiedad_id}'."}, %{state | messages: mensajes_actuales}}
      _  -> {:reply, {:ok, filtrados}, %{state | messages: mensajes_actuales}}
    end
  end

  # ---- PRIVADO ----

  # Si el usuario está online, le enviamos el mensaje directamente a su proceso CLI.
  # send/2 nunca falla aunque el PID esté muerto (el mensaje simplemente se descarta).
  defp notificar_si_online(online, username, msg) do
    case Map.get(online, username) do
      nil -> :ok
      pid -> send(pid, {:new_message, msg})
    end
  end

  # ---- PERSISTENCIA JSON ----

  defp load_messages do
    case File.read(@messages_file) do
      {:ok, content} ->
        content = String.trim(content)
        if content == "" do
          []
        else
          content
          |> JSON.decode!()
          |> Enum.map(&atomize_keys/1)
        end

      {:error, _} ->
        []
    end
  end

  defp save_messages(messages) do
    File.write(@messages_file, JSON.encode!(messages))
  end

  # Convierte claves string (que devuelve JSON.decode!) a átomos
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
