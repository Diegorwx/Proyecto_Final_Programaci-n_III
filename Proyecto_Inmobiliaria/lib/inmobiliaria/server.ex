defmodule Inmobiliaria.Server do
  @moduledoc """
  Servidor principal del sistema. Maneja la interfaz CLI,
  recibe comandos y los despacha a los módulos correspondientes.
  """

  @puntos_cliente 10
  @puntos_propietario 15

  def start do
    IO.puts("""
    ========================================
      Bienvenido al Sistema de Inmobiliaria
    ========================================
    Escribe 'help' para ver los comandos disponibles.
    """)

    loop(nil)
  end

  # ---- LOOP PRINCIPAL ----

  defp loop(user) do
    prompt = if user, do: "[#{user.username}@#{user.rol}]> ", else: "> "
    input = IO.gets(prompt) |> String.trim()

    case String.split(input, " ", parts: 2) do
      ["help"] -> handle("help", user) |> loop()
      ["connect", args] -> handle({:connect, args}, user) |> loop()
      ["disconnect"] -> handle(:disconnect, user) |> loop()
      ["list_properties"] -> handle(:list_properties, user) |> loop()
      ["list_locations"] -> handle(:list_locations, user) |> loop()
      ["filter_properties", args] -> handle({:filter_properties, args}, user) |> loop()
      ["publish_property", args] -> handle({:publish_property, args}, user) |> loop()
      ["buy_property", args] -> handle({:buy_property, args}, user) |> loop()
      ["rent_property", args] -> handle({:rent_property, args}, user) |> loop()
      ["send_message", args] -> handle({:send_message, args}, user) |> loop()
      ["my_messages"] -> handle(:my_messages, user) |> loop()
      ["my_score"] -> handle(:my_score, user) |> loop()
      ["ranking"] -> handle(:ranking, user) |> loop()
      ["ranking", rol] -> handle({:ranking_by_rol, rol}, user) |> loop()
      ["exit"] -> IO.puts("Hasta luego."); exit(:normal)
      _ -> IO.puts("Comando no reconocido. Escribe 'help'."); loop(user)
    end
  end

  # ---- HANDLERS ----

  defp handle("help", user) do
    IO.puts("""
    Comandos disponibles:
      connect <username> <password> <rol>   - Conectarse o registrarse
      disconnect                            - Desconectarse
      list_properties                       - Ver todas las propiedades
      list_locations                        - Ver ubicaciones válidas
      filter_properties <filtros>           - Filtrar propiedades
      publish_property <datos>              - Publicar una propiedad (vendedor/arrendador)
      buy_property <id>                     - Comprar una propiedad (cliente)
      rent_property <id>                    - Arrendar una propiedad (cliente)
      send_message <id> <mensaje>           - Enviar mensaje al propietario
      my_messages                           - Ver tus mensajes recibidos
      my_score                              - Ver tu puntaje actual
      ranking                               - Ver ranking global
      ranking <rol>                         - Ver ranking por rol
      exit                                  - Salir del sistema
    """)
    user
  end

  defp handle({:connect, args}, _user) do
    case String.split(args, " ") do
      [username, password, rol] ->
        case Inmobiliaria.UserManager.connect(username, password, rol) do
          {:ok, user} ->
            IO.puts("Bienvenido, #{user.username} (#{user.rol}).")
            user

          {:error, msg} ->
            IO.puts("Error: #{msg}")
            nil
        end

      _ ->
        IO.puts("Uso: connect <username> <password> <rol>")
        nil
    end
  end

  defp handle(:disconnect, user) do
    if user do
      IO.puts("Hasta luego, #{user.username}.")
    else
      IO.puts("No hay sesión activa.")
    end
    nil
  end

  defp handle(:list_properties, user) do
    case Inmobiliaria.PropertyManager.list_all() do
      {:ok, props} ->
        IO.puts("\n--- Propiedades registradas ---")
        Enum.each(props, &print_property/1)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    user
  end

  defp handle(:list_locations, user) do
    case Inmobiliaria.Location.list_locations() do
      {:ok, locs} ->
        IO.puts("\n--- Ubicaciones disponibles ---")
        Enum.each(locs, fn l -> IO.puts("  • #{l}") end)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    user
  end

  defp handle({:filter_properties, args}, user) do
    params = parse_params(args)

    filters = [
      tipo: Map.get(params, "tipo"),
      modalidad: Map.get(params, "modalidad"),
      ubicacion: Map.get(params, "ubicacion"),
      precio_min: parse_int(Map.get(params, "precio_min")),
      precio_max: parse_int(Map.get(params, "precio_max"))
    ]

    case Inmobiliaria.PropertyManager.filter(filters) do
      {:ok, props} ->
        IO.puts("\n--- Resultados ---")
        Enum.each(props, &print_property/1)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    user
  end

  defp handle({:publish_property, args}, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      params = parse_params(args)

      case Inmobiliaria.PropertyManager.publish(
             user.username,
             user.rol,
             Map.get(params, "tipo"),
             Map.get(params, "modalidad"),
             Map.get(params, "ubicacion"),
             parse_int(Map.get(params, "precio")),
             parse_int(Map.get(params, "habitaciones")),
             parse_float(Map.get(params, "area"))
           ) do
        {:ok, prop} ->
          IO.puts("Propiedad publicada con ID: #{prop.id}")
        {:error, msg} ->
          IO.puts("Error: #{msg}")
      end
    end
    user
  end

  defp handle({:buy_property, id}, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      if user.rol != "cliente" do
        IO.puts("Solo los clientes pueden comprar propiedades.")
      else
        case Inmobiliaria.Property.buy(id, user.username) do
          {:ok, prop} ->
            Inmobiliaria.PropertyManager.update_estado(id, "vendida")
            Inmobiliaria.UserManager.add_points(user.username, @puntos_cliente)
            Inmobiliaria.UserManager.add_points(prop.propietario, @puntos_propietario)
            log_operation(user.username, prop, "compra")
            IO.puts("Compra exitosa. Propiedad #{id} ahora es tuya. +#{@puntos_cliente} puntos.")
          {:error, msg} ->
            IO.puts("Error: #{msg}")
        end
      end
    end
    user
  end

  defp handle({:rent_property, id}, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      if user.rol != "cliente" do
        IO.puts("Solo los clientes pueden arrendar propiedades.")
      else
        case Inmobiliaria.Property.rent(id, user.username) do
          {:ok, prop} ->
            Inmobiliaria.PropertyManager.update_estado(id, "arrendada")
            Inmobiliaria.UserManager.add_points(user.username, @puntos_cliente)
            Inmobiliaria.UserManager.add_points(prop.propietario, @puntos_propietario)
            log_operation(user.username, prop, "arriendo")
            IO.puts("Arriendo exitoso. Propiedad #{id} arrendada. +#{@puntos_cliente} puntos.")
          {:error, msg} ->
            IO.puts("Error: #{msg}")
        end
      end
    end
    user
  end

  defp handle({:send_message, args}, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case String.split(args, " ", parts: 2) do
        [propiedad_id, mensaje] ->
          case Inmobiliaria.MessageManager.send_message(user.username, propiedad_id, mensaje) do
            {:ok, _} -> IO.puts("Mensaje enviado.")
            {:error, msg} -> IO.puts("Error: #{msg}")
          end
        _ ->
          IO.puts("Uso: send_message <propiedad_id> <mensaje>")
      end
    end
    user
  end

  defp handle(:my_messages, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case Inmobiliaria.MessageManager.get_messages_for(user.username) do
        {:ok, msgs} ->
          IO.puts("\n--- Tus mensajes ---")
          Enum.each(msgs, fn m ->
            IO.puts("[#{m.fecha}] De: #{m.de} | Propiedad: #{m.propiedad_id}")
            IO.puts("  #{m.mensaje}")
          end)
        {:error, msg} ->
          IO.puts(msg)
      end
    end
    user
  end

  defp handle(:my_score, user) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case Inmobiliaria.UserManager.get_user(user.username) do
        {:ok, u} -> IO.puts("Tu puntaje actual: #{u.puntaje} puntos.")
        {:error, msg} -> IO.puts("Error: #{msg}")
      end
    end
    user
  end

  defp handle(:ranking, user) do
    case Inmobiliaria.UserManager.ranking() do
      {:ok, ranked} ->
        IO.puts("\n--- Ranking Global ---")
        Enum.each(ranked, fn u ->
          IO.puts("#{u.posicion}. #{u.username} (#{u.rol}) - #{u.puntaje} pts")
        end)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    user
  end

  defp handle({:ranking_by_rol, rol}, user) do
    case Inmobiliaria.UserManager.ranking_by_rol(rol) do
      {:ok, ranked} ->
        IO.puts("\n--- Ranking: #{rol} ---")
        Enum.each(ranked, fn u ->
          IO.puts("#{u.posicion}. #{u.username} - #{u.puntaje} pts")
        end)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    user
  end

  # ---- HELPERS ----

  defp print_property(p) do
    IO.puts("""
      [#{p.id}] #{p.tipo} en #{p.ubicacion}
        Modalidad: #{p.modalidad} | Precio: $#{p.precio}
        Habitaciones: #{p.habitaciones} | Área: #{p.area}m²
        Estado: #{p.estado} | Propietario: #{p.propietario}
    """)
  end

  defp log_operation(cliente, prop, tipo) do
    linea =
      "#{Date.utc_today()}; cliente=#{cliente}; responsable=#{prop.propietario}; " <>
      "propiedad=#{prop.id}; operacion=#{tipo}; ubicacion=#{prop.ubicacion}; " <>
      "precio=#{prop.precio}; status=Completada\n"

    File.write("data/results.log", linea, [:append])
  end

  defp parse_params(args) do
    args
    |> String.split(" ")
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.into(%{}, fn [k, v] -> {k, v} end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(val), do: String.to_integer(val)

  defp parse_float(nil), do: nil
  defp parse_float(val), do: String.to_float(val)
  
end
