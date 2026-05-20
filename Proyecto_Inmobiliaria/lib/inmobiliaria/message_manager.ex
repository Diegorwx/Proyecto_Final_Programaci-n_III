defmodule Inmobiliaria.MessageManager do
  @moduledoc """
  Gestión de mensajes entre clientes y propietarios.
  Los mensajes se persisten en data/messages.log.
  """

  @messages_file "data/messages.log"

  # ---- PERSISTENCIA ----

  defp load_messages do
    case File.read(@messages_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_message/1)

      {:error, _} ->
        []
    end
  end

  defp parse_message(line) do
    [fecha, de, para, propiedad_id, mensaje] = String.split(line, ";", parts: 5)

    %{
      fecha: fecha,
      de: de,
      para: para,
      propiedad_id: propiedad_id,
      mensaje: mensaje
    }
  end

  defp save_message(msg) do
    line = "#{msg.fecha};#{msg.de};#{msg.para};#{msg.propiedad_id};#{msg.mensaje}\n"
    File.write(@messages_file, line, [:append])
  end

  # ---- API PÚBLICA ----

  @doc """
  Envía un mensaje de un cliente al propietario de una propiedad.
  Retorna {:ok, message} o {:error, mensaje}.
  """
  def send_message(de, propiedad_id, mensaje) do
    case Inmobiliaria.PropertyManager.get(propiedad_id) do
      {:error, msg} ->
        {:error, msg}

      {:ok, propiedad} ->
        msg = %{
          fecha: Date.utc_today() |> Date.to_string(),
          de: de,
          para: propiedad.propietario,
          propiedad_id: propiedad_id,
          mensaje: mensaje
        }

        save_message(msg)
        {:ok, msg}
    end
  end

  @doc """
  Lista todos los mensajes recibidos por un propietario.
  """
  def get_messages_for(propietario) do
    messages = load_messages()

    filtered = Enum.filter(messages, fn m -> m.para == propietario end)

    case filtered do
      [] -> {:error, "No tienes mensajes."}
      msgs -> {:ok, msgs}
    end
  end

  @doc """
  Lista todos los mensajes asociados a una propiedad específica.
  """
  def get_messages_by_property(propiedad_id) do
    messages = load_messages()

    filtered = Enum.filter(messages, fn m -> m.propiedad_id == propiedad_id end)

    case filtered do
      [] -> {:error, "No hay mensajes para la propiedad '#{propiedad_id}'."}
      msgs -> {:ok, msgs}
    end
  end
end
