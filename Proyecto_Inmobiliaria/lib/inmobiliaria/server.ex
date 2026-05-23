defmodule Inmobiliaria.Server do
  @moduledoc """
  Servidor principal del sistema. Maneja la interfaz CLI,
  recibe comandos del usuario y los despacha a los módulos correspondientes.

  Soporte para nodos distribuidos: las operaciones se pueden redirigir
  a un nodo remoto con 'connect_node <nodo@host>'.
  """

  @puntos_cliente    10
  @puntos_propietario 15

  def start do
    IO.puts("""
    ============================================
      Bienvenido al Sistema de Inmobiliaria
    ============================================
    Escribe 'help' para ver los comandos disponibles.
    """)

    loop(nil, node())
  end

  # ---- LOOP PRINCIPAL ----

  defp loop(user, snode) do
    node_tag = if snode != node(), do: " [→#{snode}]", else: ""
    prompt   = if user, do: "[#{user.username}@#{user.rol}#{node_tag}]> ", else: "> "
    input    = IO.gets(prompt) |> String.trim()

    {new_user, new_snode} = case String.split(input, " ", parts: 2) do
      ["help"]                       -> handle(:help, user, snode)
      ["connect", args]              -> handle({:connect, args}, user, snode)
      ["disconnect"]                 -> handle(:disconnect, user, snode)
      ["list_properties"]            -> handle(:list_properties, user, snode)
      ["list_locations"]             -> handle(:list_locations, user, snode)
      ["filter_properties", args]    -> handle({:filter_properties, args}, user, snode)
      ["publish_property", args]     -> handle({:publish_property, args}, user, snode)
      ["buy_property", id]           -> handle({:buy_property, id}, user, snode)
      ["rent_property", id]          -> handle({:rent_property, id}, user, snode)
      ["reserve_property", id]       -> handle({:reserve_property, id}, user, snode)
      ["cancel_reservation", id]     -> handle({:cancel_reservation, id}, user, snode)
      ["property_info", id]          -> handle({:property_info, id}, user, snode)
      ["send_message", args]         -> handle({:send_message, args}, user, snode)
      ["reply_message", args]        -> handle({:reply_message, args}, user, snode)
      ["my_messages"]                -> handle(:my_messages, user, snode)
      ["property_messages", id]      -> handle({:property_messages, id}, user, snode)
      ["my_score"]                   -> handle(:my_score, user, snode)
      ["ranking"]                    -> handle(:ranking, user, snode)
      ["ranking", rol]               -> handle({:ranking_by_rol, rol}, user, snode)
      ["connect_node", args]         -> handle({:connect_node, args}, user, snode)
      ["disconnect_node"]            -> handle(:disconnect_node, user, snode)
      ["exit"]                       -> IO.puts("Hasta luego."); exit(:normal)
      _                              -> IO.puts("Comando no reconocido. Escribe 'help'."); {user, snode}
    end

    # Revisamos el buzón del proceso por mensajes nuevos recibidos en tiempo real.
    # Esto permite que el chat funcione sin bloquear la entrada de comandos.
    mostrar_mensajes_pendientes()

    loop(new_user, new_snode)
  end

  # ---- HANDLERS ----

  defp handle(:help, user, snode) do
    IO.puts("""
    Comandos disponibles:
    ── Sesión ─────────────────────────────────────────────────────────────
      connect <username> <password> <rol>    Conectarse o registrarse
                                             Roles: cliente / vendedor / arrendador
      disconnect                             Desconectarse
    ── Propiedades ────────────────────────────────────────────────────────
      list_properties                        Ver todas las propiedades
      list_locations                         Ver ubicaciones válidas
      filter_properties <filtros>            Filtrar: tipo=X modalidad=X ubicacion=X
                                                       precio_min=X precio_max=X
      publish_property <datos>               Publicar (vendedor/arrendador)
                                             tipo=X modalidad=X ubicacion=X precio=X
                                             habitaciones=X area=X banios=X
                                             parking=si/no amoblado=si/no
                                             descripcion=texto_con_guiones_bajos
      property_info <id>                     Ver descripción completa de una propiedad
    ── Transacciones ──────────────────────────────────────────────────────
      buy_property <id>                      Comprar una propiedad (cliente)
      rent_property <id>                     Arrendar una propiedad (cliente)
      reserve_property <id>                  Reservar por 30 min (cliente)
      cancel_reservation <id>               Cancelar tu reserva (cliente)
    ── Mensajería en tiempo real ──────────────────────────────────────────
      send_message <id> <mensaje>            Escribir al propietario de una propiedad
      reply_message <id> <cliente> <mensaje> Responder a un cliente (propietario)
      my_messages                            Ver mensajes recibidos
      property_messages <id>                 Ver historial de chat de una propiedad
    ── Ranking ────────────────────────────────────────────────────────────
      my_score                               Ver tu puntaje actual
      ranking                                Ver ranking global
      ranking compradores                    Ranking de clientes/compradores
      ranking vendedores                     Ranking de vendedores
      ranking arrendadores                   Ranking de arrendadores
    ── Nodos distribuidos ─────────────────────────────────────────────────
      connect_node <nodo@host>               Conectarse a un nodo servidor remoto
      disconnect_node                        Volver al nodo local
      exit                                   Salir del sistema
    """)
    {user, snode}
  end

  defp handle({:connect, args}, user, snode) do
    case String.split(args, " ") do
      [username, password, rol] ->
        case Inmobiliaria.UserManager.connect(username, password, rol, snode) do
          {:ok, new_user} ->
            # si ya había sesión activa, limpiarla antes de registrar la nueva
            # para no dejar PIDs huérfanos en el MessageManager
            if user, do: rpc(snode, Inmobiliaria.MessageManager, :unregister_session, [user.username])
            rpc(snode, Inmobiliaria.MessageManager, :register_session, [username, self()])
            IO.puts("Bienvenido, #{new_user.username} (#{new_user.rol}).")
            {new_user, snode}

          {:error, msg} ->
            IO.puts("Error: #{msg}")
            {nil, snode}
        end

      _ ->
        IO.puts("Uso: connect <username> <password> <rol>")
        {nil, snode}
    end
  end

  defp handle(:disconnect, user, snode) do
    if user do
      rpc(snode, Inmobiliaria.MessageManager, :unregister_session, [user.username])
      IO.puts("Hasta luego, #{user.username}.")
    else
      IO.puts("No hay sesión activa.")
    end
    {nil, snode}
  end

  defp handle(:list_properties, user, snode) do
    case Inmobiliaria.PropertyManager.list_all(snode) do
      {:ok, props} ->
        IO.puts("\n--- Propiedades registradas (#{length(props)}) ---")
        Enum.each(props, &print_property/1)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    {user, snode}
  end

  defp handle(:list_locations, user, snode) do
    case rpc(snode, Inmobiliaria.Location, :list_locations, []) do
      {:ok, locs} ->
        IO.puts("\n--- Ubicaciones disponibles ---")
        Enum.each(locs, fn l -> IO.puts("  • #{l}") end)
      {:error, msg}    -> IO.puts("Error: #{msg}")
      {:badrpc, reason} -> IO.puts("Error de red: #{inspect(reason)}")
    end
    {user, snode}
  end

  defp handle({:filter_properties, args}, user, snode) do
    params = parse_params(args)

    filters = [
      tipo:       Map.get(params, "tipo"),
      modalidad:  Map.get(params, "modalidad"),
      ubicacion:  Map.get(params, "ubicacion"),
      precio_min: parse_int(Map.get(params, "precio_min")),
      precio_max: parse_int(Map.get(params, "precio_max"))
    ]

    case Inmobiliaria.PropertyManager.filter(filters, snode) do
      {:ok, props} ->
        IO.puts("\n--- Resultados del filtro ---")
        Enum.each(props, &print_property/1)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    {user, snode}
  end

  defp handle({:publish_property, args}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      params = parse_params(args)

      # Descripcion: los guiones bajos se convierten en espacios
      descripcion =
        Map.get(params, "descripcion", "")
        |> String.replace("_", " ")

      case Inmobiliaria.PropertyManager.publish(
             user.username,
             user.rol,
             Map.get(params, "tipo"),
             Map.get(params, "modalidad"),
             Map.get(params, "ubicacion"),
             parse_int(Map.get(params, "precio")),
             parse_int(Map.get(params, "habitaciones")),
             parse_float(Map.get(params, "area")),
             parse_int(Map.get(params, "banios")) || 1,
             parse_bool(Map.get(params, "parking", "no")),
             parse_bool(Map.get(params, "amoblado", "no")),
             descripcion,
             snode
           ) do
        {:ok, prop} ->
          IO.puts("Propiedad publicada con ID: #{prop.id}")
        {:error, msg} ->
          IO.puts("Error: #{msg}")
      end
    end
    {user, snode}
  end

  defp handle({:property_info, id}, user, snode) do
    case Inmobiliaria.PropertyManager.get(id, snode) do
      {:ok, prop} ->
        print_property_full(prop)

        # Si está reservada, consultamos los detalles de reserva al GenServer de la propiedad
        if prop.estado == "reservada" do
          case rpc(snode, Inmobiliaria.Property, :get, [id]) do
            {:ok, p} when not is_nil(p.reservado_por) ->
              IO.puts("  Reservada por: #{p.reservado_por}")
              IO.puts("  Expira aprox.: #{p.reservado_hasta}")
            _ -> :ok
          end
        end

      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    {user, snode}
  end

  defp handle({:buy_property, id}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      if user.rol != "cliente" do
        IO.puts("Solo los clientes pueden comprar propiedades.")
      else
        case rpc(snode, Inmobiliaria.Property, :buy, [id, user.username]) do
          {:ok, prop} ->
            Inmobiliaria.PropertyManager.update_estado(id, "vendida", snode)
            Inmobiliaria.UserManager.add_points(user.username, @puntos_cliente, snode)
            Inmobiliaria.UserManager.add_points(prop.propietario, @puntos_propietario, snode)
            log_operation(user.username, prop, "compra", snode)
            IO.puts("Compra exitosa. Propiedad #{id} ahora es tuya. +#{@puntos_cliente} puntos.")
          {:error, msg} ->
            IO.puts("Error: #{msg}")
          {:badrpc, _} ->
            IO.puts("Error: Propiedad '#{id}' no encontrada en el servidor.")
        end
      end
    end
    {user, snode}
  end

  defp handle({:rent_property, id}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      if user.rol != "cliente" do
        IO.puts("Solo los clientes pueden arrendar propiedades.")
      else
        case rpc(snode, Inmobiliaria.Property, :rent, [id, user.username]) do
          {:ok, prop} ->
            Inmobiliaria.PropertyManager.update_estado(id, "arrendada", snode)
            Inmobiliaria.UserManager.add_points(user.username, @puntos_cliente, snode)
            Inmobiliaria.UserManager.add_points(prop.propietario, @puntos_propietario, snode)
            log_operation(user.username, prop, "arriendo", snode)
            IO.puts("Arriendo exitoso. Propiedad #{id} arrendada. +#{@puntos_cliente} puntos.")
          {:error, msg} ->
            IO.puts("Error: #{msg}")
          {:badrpc, _} ->
            IO.puts("Error: Propiedad '#{id}' no encontrada en el servidor.")
        end
      end
    end
    {user, snode}
  end

  defp handle({:reserve_property, id}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      if user.rol != "cliente" do
        IO.puts("Solo los clientes pueden reservar propiedades.")
      else
        case rpc(snode, Inmobiliaria.Property, :reserve, [id, user.username]) do
          {:ok, _prop} ->
            Inmobiliaria.PropertyManager.update_estado(id, "reservada", snode)
            IO.puts("""
            Propiedad #{id} reservada por 30 minutos.
            Durante ese tiempo solo tú puedes comprarla o arrendarla.
            Usa 'cancel_reservation #{id}' si cambias de opinión.
            """)
          {:error, msg} ->
            IO.puts("Error: #{msg}")
          {:badrpc, _} ->
            IO.puts("Error: Propiedad '#{id}' no encontrada en el servidor.")
        end
      end
    end
    {user, snode}
  end

  defp handle({:cancel_reservation, id}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case rpc(snode, Inmobiliaria.Property, :cancel_reservation, [id, user.username]) do
        {:ok, _} ->
          Inmobiliaria.PropertyManager.update_estado(id, "disponible", snode)
          IO.puts("Reserva de la propiedad #{id} cancelada. Vuelve a estar disponible.")
        {:error, msg} ->
          IO.puts("Error: #{msg}")
        {:badrpc, _} ->
          IO.puts("Error: Propiedad '#{id}' no encontrada en el servidor.")
      end
    end
    {user, snode}
  end

  defp handle({:send_message, args}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case String.split(args, " ", parts: 2) do
        [propiedad_id, mensaje] ->
          case rpc(snode, Inmobiliaria.MessageManager, :send_message, [user.username, propiedad_id, mensaje]) do
            {:ok, _}           -> IO.puts("Mensaje enviado. El propietario será notificado.")
            {:error, msg}      -> IO.puts("Error: #{msg}")
            {:badrpc, reason}  -> IO.puts("Error de red: #{inspect(reason)}")
          end
        _ ->
          IO.puts("Uso: send_message <propiedad_id> <mensaje>")
      end
    end
    {user, snode}
  end

  defp handle({:reply_message, args}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case String.split(args, " ", parts: 3) do
        [propiedad_id, cliente, mensaje] ->
          case rpc(snode, Inmobiliaria.MessageManager, :reply_message,
                   [user.username, propiedad_id, cliente, mensaje]) do
            {:ok, _}           -> IO.puts("Respuesta enviada a '#{cliente}'.")
            {:error, msg}      -> IO.puts("Error: #{msg}")
            {:badrpc, reason}  -> IO.puts("Error de red: #{inspect(reason)}")
          end
        _ ->
          IO.puts("Uso: reply_message <propiedad_id> <cliente_username> <mensaje>")
      end
    end
    {user, snode}
  end

  defp handle(:my_messages, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case rpc(snode, Inmobiliaria.MessageManager, :get_messages_for, [user.username]) do
        {:ok, msgs} ->
          IO.puts("\n--- Mensajes recibidos (#{length(msgs)}) ---")
          Enum.each(msgs, fn m ->
            IO.puts("[#{m.fecha}] De: #{m.de} | Propiedad: #{m.propiedad_id}")
            IO.puts("  #{m.mensaje}")
            IO.puts("")
          end)
        {:error, msg}     -> IO.puts(msg)
        {:badrpc, reason} -> IO.puts("Error de red: #{inspect(reason)}")
      end
    end
    {user, snode}
  end

  defp handle({:property_messages, id}, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case rpc(snode, Inmobiliaria.MessageManager, :get_messages_by_property, [id]) do
        {:ok, msgs} ->
          IO.puts("\n--- Historial de mensajes: propiedad #{id} ---")
          Enum.each(msgs, fn m ->
            IO.puts("[#{m.fecha}] #{m.de} → #{m.para}")
            IO.puts("  #{m.mensaje}")
            IO.puts("")
          end)
        {:error, msg}     -> IO.puts(msg)
        {:badrpc, reason} -> IO.puts("Error de red: #{inspect(reason)}")
      end
    end
    {user, snode}
  end

  defp handle(:my_score, user, snode) do
    if is_nil(user) do
      IO.puts("Debes conectarte primero.")
    else
      case Inmobiliaria.UserManager.get_user(user.username, snode) do
        {:ok, u}      -> IO.puts("Tu puntaje actual: #{u.puntaje} puntos.")
        {:error, msg} -> IO.puts("Error: #{msg}")
      end
    end
    {user, snode}
  end

  defp handle(:ranking, user, snode) do
    case Inmobiliaria.UserManager.ranking(snode) do
      {:ok, ranked} ->
        IO.puts("\n--- Ranking Global ---")
        Enum.each(ranked, fn u ->
          IO.puts("  #{u.posicion}. #{u.username} (#{etiqueta_rol(u.rol)}) — #{u.puntaje} pts")
        end)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    {user, snode}
  end

  defp handle({:ranking_by_rol, rol_raw}, user, snode) do
    rol = normalizar_rol(rol_raw)

    case Inmobiliaria.UserManager.ranking_by_rol(rol, snode) do
      {:ok, ranked} ->
        IO.puts("\n--- Ranking: #{etiqueta_rol(rol)} ---")
        Enum.each(ranked, fn u ->
          IO.puts("  #{u.posicion}. #{u.username} — #{u.puntaje} pts")
        end)
      {:error, msg} ->
        IO.puts("Error: #{msg}")
    end
    {user, snode}
  end

  defp handle({:connect_node, node_name}, user, snode) do
    target = String.to_atom(node_name)
    case Node.connect(target) do
      true ->
        # si el usuario ya está logueado, mover su registro de sesión
        # al nuevo nodo para que siga recibiendo notificaciones en tiempo real
        if user do
          rpc(snode, Inmobiliaria.MessageManager, :unregister_session, [user.username])
          rpc(target, Inmobiliaria.MessageManager, :register_session, [user.username, self()])
        end
        IO.puts("Conectado al nodo #{node_name}. Las operaciones se redirigen a ese nodo.")
        {user, target}
      false ->
        IO.puts("No se pudo conectar al nodo #{node_name}.")
        {user, snode}
      :ignored ->
        IO.puts("Nodo local, sin cambios.")
        {user, snode}
    end
  end

  defp handle(:disconnect_node, user, _snode) do
    IO.puts("Desconectado del nodo remoto. Operando en nodo local.")
    {user, node()}
  end

  # ---- TIEMPO REAL: revisar mensajes pendientes ----

  # Después de cada comando del CLI revisamos el buzón del proceso.
  # Si otro usuario nos envió un mensaje mientras ejecutábamos un comando,
  # lo mostramos aquí sin interrumpir la entrada.
  defp mostrar_mensajes_pendientes do
    receive do
      {:new_message, msg} ->
        IO.puts("""

        ╔══ MENSAJE NUEVO ══════════════════════════╗
          De: #{msg.de}  |  Propiedad: #{msg.propiedad_id}
          "#{msg.mensaje}"
        ╚═══════════════════════════════════════════╝
        """)
        # Seguimos revisando por si hay más mensajes pendientes
        mostrar_mensajes_pendientes()
    after
      0 -> :ok
    end
  end

  # ---- HELPERS DE VISUALIZACIÓN ----

  # Vista resumida para listados y resultados de filtros
  defp print_property(p) do
    parking_txt  = if p.parking,  do: "Sí", else: "No"
    amoblado_txt = if p.amoblado, do: "Sí", else: "No"

    IO.puts("""
      [#{p.id}] #{p.tipo} en #{p.ubicacion}
        Modalidad: #{p.modalidad} | Precio: $#{p.precio}
        Habitaciones: #{p.habitaciones} | Baños: #{p.banios} | Área: #{p.area}m²
        Parking: #{parking_txt} | Amoblado: #{amoblado_txt}
        Estado: #{p.estado} | Propietario: #{p.propietario}
    """)
  end

  # Vista completa para 'property_info' — muestra todos los campos detallados
  defp print_property_full(p) do
    parking_txt  = if p.parking,  do: "Sí", else: "No"
    amoblado_txt = if p.amoblado, do: "Sí", else: "No"

    descripcion_txt =
      if p.descripcion && p.descripcion != "",
        do: p.descripcion,
        else: "(sin descripción)"

    IO.puts("""

    ════════════════════════════════════════════
      Propiedad #{p.id} — #{p.tipo}
    ════════════════════════════════════════════
      Ubicación:    #{p.ubicacion}
      Modalidad:    #{p.modalidad}
      Precio:       $#{p.precio}
      Estado:       #{p.estado}
      Propietario:  #{p.propietario}

    ── Características ──────────────────────────
      Habitaciones: #{p.habitaciones}
      Baños:        #{p.banios}
      Área:         #{p.area} m²
      Parking:      #{parking_txt}
      Amoblado:     #{amoblado_txt}

    ── Descripción ──────────────────────────────
      #{descripcion_txt}
    ════════════════════════════════════════════
    """)
  end

  # ---- HELPERS DE RANKING ----

  # Acepta variantes en español (singular/plural) para los roles
  defp normalizar_rol("compradores"),  do: "cliente"
  defp normalizar_rol("comprador"),    do: "cliente"
  defp normalizar_rol("clientes"),     do: "cliente"
  defp normalizar_rol("vendedores"),   do: "vendedor"
  defp normalizar_rol("arrendadores"), do: "arrendador"
  defp normalizar_rol(otro),           do: otro

  # Etiqueta amigable para mostrar en rankings
  defp etiqueta_rol("cliente"),    do: "Comprador/Cliente"
  defp etiqueta_rol("vendedor"),   do: "Vendedor"
  defp etiqueta_rol("arrendador"), do: "Arrendador"
  defp etiqueta_rol(otro),         do: otro

  # ---- HELPERS GENERALES ----

  defp log_operation(cliente, prop, tipo, snode) do
    linea =
      "#{Date.utc_today()}; cliente=#{cliente}; responsable=#{prop.propietario}; " <>
      "propiedad=#{prop.id}; operacion=#{tipo}; ubicacion=#{prop.ubicacion}; " <>
      "precio=#{prop.precio}; status=Completada\n"

    rpc(snode, File, :write, ["data/results.log", linea, [:append]])
  end

  defp rpc(snode, module, fun, args) do
    if snode == node() do
      apply(module, fun, args)
    else
      :rpc.call(snode, module, fun, args)
    end
  end

  defp parse_params(args) do
    args
    |> String.split(" ")
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.filter(&match?([_, _], &1))
    |> Enum.into(%{}, fn [k, v] -> {k, v} end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error  -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error  -> nil
    end
  end

  defp parse_bool("si"),  do: true
  defp parse_bool("sí"),  do: true
  defp parse_bool("yes"), do: true
  defp parse_bool(_),     do: false
end
