# Guía de Sustentación — Sistema de Inmobiliaria Virtual en Elixir

---

## ÍNDICE

1. [Cómo correr la aplicación](#1-cómo-correr-la-aplicación)
2. [Arquitectura general — qué es cada pieza](#2-arquitectura-general)
3. [Explicación técnica módulo por módulo](#3-explicación-técnica-módulo-por-módulo)
4. [Conceptos OTP que debes dominar](#4-conceptos-otp-que-debes-dominar)
5. [Flujos de prueba para la sustentación](#5-flujos-de-prueba-para-la-sustentación)
6. [Preguntas difíciles que pueden hacerte](#6-preguntas-difíciles-que-pueden-hacerte)

---

## 1. CÓMO CORRER LA APLICACIÓN

### Prerrequisitos
- Elixir 1.18+ instalado
- En el directorio: `Proyecto_Final_Programaci-n_III/Proyecto_Inmobiliaria/`

### Escenario A — Un solo nodo (una terminal)

```bash
# 1. Entrar al directorio del proyecto
cd Proyecto_Inmobiliaria

# 2. Arrancar iex con nombre y cookie (SIEMPRE con nombre para poder distribuir luego)
iex --name servidor@192.168.1.20 --cookie inmobiliaria -S mix

# 3. Dentro de iex, iniciar el CLI
iex(servidor@192.168.1.20)1> Inmobiliaria.Application.start_cli()
```

A partir de ahí el sistema muestra el prompt `>` y puedes escribir comandos.

---

### Escenario B — Dos nodos, misma PC (dos terminales)

**Terminal 1 — Nodo servidor:**
```bash
iex --name servidor@192.168.1.20 --cookie inmobiliaria -S mix
# Dentro de iex:
Inmobiliaria.Application.start_cli()
```

**Terminal 2 — Nodo cliente (misma IP, diferente nombre):**
```bash
iex --name cliente2@192.168.1.20 --cookie inmobiliaria -S mix
# Dentro de iex:
Inmobiliaria.Application.start_cli()
# Desde el CLI:
connect_node servidor@192.168.1.20
```

---

### Escenario C — Dos nodos, dos PCs distintas

**PC servidor (192.168.1.20):**
```bash
iex --name servidor@192.168.1.20 --cookie inmobiliaria -S mix
Inmobiliaria.Application.start_cli()
```

**Otro PC (192.168.1.X):**
```bash
iex --name cliente1@192.168.1.X --cookie inmobiliaria -S mix
Inmobiliaria.Application.start_cli()
# Desde el CLI:
connect_node servidor@192.168.1.20
```

> **Puntos clave para conectar nodos:**
> - El `--cookie` debe ser **idéntico** en todos los nodos. Es la clave de autenticación.
> - El `--name` usa la IP real de la máquina (no localhost).
> - Ambas máquinas deben estar en la misma red y poder hacer ping entre sí.
> - Puerto 4369 (epmd) no debe estar bloqueado por firewall.

---

### Orden de arranque del árbol OTP (automático al hacer `-S mix`)

Cuando arranca la aplicación, `application.ex` ejecuta esto en orden:

```
1. Arranca Inmobiliaria.MainSupervisor (supervisor estático)
   ├─ 2. Arranca Inmobiliaria.Supervisor (DynamicSupervisor vacío)
   ├─ 3. Arranca Inmobiliaria.UserManager  → carga users.json
   ├─ 4. Arranca Inmobiliaria.PropertyManager → carga properties.json
   └─ 5. Arranca Inmobiliaria.MessageManager → carga messages.json

6. restore_property_processes():
   Lee todas las propiedades del PropertyManager y lanza
   un proceso Inmobiliaria.Property por cada una bajo el DynamicSupervisor.
```

Todo esto ocurre antes de que el usuario escriba el primer comando.

---

## 2. ARQUITECTURA GENERAL

### Árbol de supervisión completo

```
Inmobiliaria.MainSupervisor  ← Supervisor estático, :one_for_one
│
├── Inmobiliaria.Supervisor  ← DynamicSupervisor (gestiona propiedades)
│   ├── :prop001             ← GenServer (Inmobiliaria.Property)
│   ├── :prop002             ← GenServer (Inmobiliaria.Property)
│   └── :propN...
│
├── Inmobiliaria.UserManager      ← GenServer (usuarios + puntajes)
├── Inmobiliaria.PropertyManager  ← GenServer (registro de propiedades)
└── Inmobiliaria.MessageManager   ← GenServer (mensajería + sesiones online)
```

### Qué es cada tipo de proceso

| Tipo | Qué hace | En este proyecto |
|---|---|---|
| `Supervisor` (estático) | Arranca hijos fijos que siempre deben existir | `MainSupervisor` — arranca los 4 workers siempre |
| `DynamicSupervisor` | Arranca hijos en tiempo de ejecución, cantidad variable | `Inmobiliaria.Supervisor` — crea un proceso por propiedad publicada |
| `GenServer` | Proceso con estado propio, recibe mensajes y responde | `UserManager`, `PropertyManager`, `MessageManager`, cada `Property` |

### Flujo de una petición (resumen)

```
Usuario escribe comando
      ↓
Server.loop/2 (pattern match)
      ↓
handle/3 → rpc/4 (local o remoto)
      ↓
GenServer correspondiente procesa y actualiza estado
      ↓
Persiste en JSON
      ↓
Server imprime resultado al usuario
      ↓
mostrar_mensajes_pendientes() — revisa buzón de mensajes nuevos
      ↓
Vuelve al loop
```

---

## 3. EXPLICACIÓN TÉCNICA MÓDULO POR MÓDULO

---

### `application.ex` — El punto de entrada OTP

```elixir
def start(_type, _args) do
  children = [
    {Inmobiliaria.Supervisor, []},
    {Inmobiliaria.UserManager, []},
    {Inmobiliaria.PropertyManager, []},
    {Inmobiliaria.MessageManager, []}
  ]
  opts = [strategy: :one_for_one, name: Inmobiliaria.MainSupervisor]
  {:ok, pid} = Supervisor.start_link(children, opts)
  restore_property_processes()
  {:ok, pid}
end
```

**Qué hace `restore_property_processes/0`:**
Al reiniciar el servidor, las propiedades ya están en `properties.json` pero sus procesos GenServer no existen todavía. Esta función los recrea todos para que operaciones como `buy_property` puedan encontrar el proceso `:prop001`, `:prop002`, etc.

**Por qué `:one_for_one`:**
Si `UserManager` falla, solo se reinicia él. Los demás procesos (PropertyManager, MessageManager) no se ven afectados. Si fuera `:one_for_all`, todos reiniciarían y se perdería el estado en memoria.

---

### `supervisor.ex` — DynamicSupervisor de propiedades

```elixir
def start_property(property_data) do
  child_spec = {Inmobiliaria.Property, property_data}
  DynamicSupervisor.start_child(__MODULE__, child_spec)
end
```

**Por qué DynamicSupervisor y no Supervisor estático:**
No se sabe cuántas propiedades habrá. Un Supervisor estático requiere conocer los hijos en tiempo de compilación. El DynamicSupervisor permite crear y destruir procesos hijos en tiempo de ejecución — exactamente lo que se necesita cuando un usuario publica una propiedad nueva.

**Si un proceso Property falla (crash):**
El DynamicSupervisor lo reinicia automáticamente con los mismos datos iniciales. La propiedad "vuelve a la vida" sin intervención manual.

---

### `user_manager.ex` — GenServer de usuarios

**Estado interno:** lista de mapas `[%{username, rol, password, puntaje}, ...]`

**Por qué GenServer y no un módulo funcional:**
El estado (lista de usuarios) necesita vivir en memoria y ser compartido entre todas las operaciones concurrentes. Si dos usuarios se conectan al mismo tiempo, el GenServer serializa las escrituras — nunca hay dos actualizaciones simultáneas al mismo archivo, evitando corrupción.

**Llamadas clave:**

```elixir
# handle_call {:connect, username, password, rol}
# Lógica: ¿existe el usuario?
#   NO → crear con puntaje 0, guardar en JSON, retornar {:ok, user}
#   SÍ → ¿contraseña correcta? → {:ok, user} o {:error, "Contraseña incorrecta"}

# handle_call {:add_points, username, puntos}
# Recorre la lista, encuentra al usuario, suma puntos, persiste.

# handle_call :ranking
# Ordena por puntaje descendente con Enum.sort_by, agrega posición con Enum.with_index(1)
```

**Persistencia JSON:**
```elixir
defp save_users(users) do
  File.write(@users_file, JSON.encode!(users))  # sobreescribe todo
end

defp load_users do
  File.read(@users_file)
  |> JSON.decode!()
  |> Enum.map(&atomize_keys/1)  # "username" → :username
end
```

`JSON.decode!` devuelve claves como strings (`"username"`). `atomize_keys` las convierte a átomos (`:username`) para poder usar `user.username` en lugar de `user["username"]`.

---

### `property_manager.ex` — GenServer de propiedades

**Estado interno:** lista de mapas de propiedad con todos los campos.

**Generación de IDs:**
```elixir
defp generar_id([]), do: "prop001"
defp generar_id(props) do
  max = props |> Enum.map(fn p ->
    p.id |> String.replace("prop", "") |> String.to_integer()
  end) |> Enum.max()
  "prop#{String.pad_leading(Integer.to_string(max + 1), 3, "0")}"
end
# props = [prop003, prop001] → max = 3 → siguiente = "prop004"
```

**Por qué guarda JSON sin timer_ref al persistir:**
```elixir
serializable = Enum.map(props, fn p ->
  estado = if p.estado == "reservada", do: "disponible", else: p.estado
  p |> Map.drop([:timer_ref, :reservado_por, :reservado_hasta])
    |> Map.put(:estado, estado)
end)
```
Los timers son referencias a procesos del sistema operativo — no se pueden serializar a JSON. Si el servidor se reinicia, los timers ya no existen; por eso las reservas se limpian al guardar.

---

### `property.ex` — GenServer por propiedad

**Nombre del proceso:** `String.to_atom(property_data.id)` → el átomo `:prop001`.

Esto permite llamarlo así desde cualquier lugar:
```elixir
GenServer.call({:prop001, nodo}, {:buy, "cliente1"})
```

**Concurrencia garantizada:**
Si `cliente1` y `cliente2` intentan comprar `prop001` al mismo tiempo, los dos mensajes llegan a la cola del proceso `:prop001`. Solo uno se procesa a la vez. El primero compra; el segundo encuentra `estado != "disponible"` y recibe error. Ningún lock, ningún semáforo — es la naturaleza del actor model.

**Reserva con timer:**
```elixir
def handle_call({:reserve, cliente}, _from, state) do
  timer_ref = Process.send_after(self(), :expire_reservation, 30 * 60 * 1000)
  # Después de 30 min, el proceso recibirá el mensaje :expire_reservation
  nuevo = %{state | estado: "reservada", reservado_por: cliente,
                    reservado_hasta: expira, timer_ref: timer_ref}
  {:reply, {:ok, nuevo}, nuevo}
end

def handle_info(:expire_reservation, state) do
  # Se ejecuta automáticamente después de 30 minutos
  Inmobiliaria.PropertyManager.update_estado(state.id, "disponible")
  {:noreply, %{state | estado: "disponible", reservado_por: nil, timer_ref: nil}}
end
```

`handle_call` es para mensajes que esperan respuesta. `handle_info` es para mensajes internos como timers — nadie espera respuesta.

---

### `message_manager.ex` — GenServer de mensajería

**Estado interno:**
```elixir
%{
  messages: [%{fecha, de, para, propiedad_id, mensaje}, ...],
  online:   %{"vendedor1" => #PID<0.234.0>, "cliente1" => #PID<0.198.0>}
}
```

**Cómo funciona el tiempo real:**

```
[Proceso CLI de cliente1]                [MessageManager]         [Proceso CLI de vendedor1]
       |                                       |                            |
       |-- send_message("prop001","Hola") ---> |                            |
       |                                       |-- send(pid_vendedor1,    --|
       |                                       |   {:new_message, msg})     |
       |                                       |                    recibe en buzón
       |                                       |                    (mailbox)
       |                                       |                    próximo loop:
       |                                       |                    mostrar_mensajes_pendientes()
       |                                       |                    → imprime banner
```

**register_session:** cuando un usuario hace `connect`, el proceso del loop llama:
```elixir
MessageManager.register_session("vendedor1", self())
# self() es el PID del proceso del loop CLI
# Se guarda en online: %{"vendedor1" => #PID<0.234.0>}
```

**mostrar_mensajes_pendientes:**
```elixir
defp mostrar_mensajes_pendientes do
  receive do
    {:new_message, msg} ->
      IO.puts("╔══ MENSAJE NUEVO ══╗ ...")
      mostrar_mensajes_pendientes()  # sigue revisando
  after
    0 -> :ok  # si no hay mensajes, retorna inmediatamente
  end
end
```
`after 0` es clave: el `receive` es normalmente bloqueante, pero `after 0` lo convierte en no-bloqueante — revisa si hay algo, si no hay continúa sin esperar.

**Por qué recarga JSON en las consultas:**
```elixir
def handle_call({:get_messages_for, para}, _from, state) do
  mensajes_actuales = load_messages()  # lee del disco siempre
  filtrados = Enum.filter(mensajes_actuales, fn m -> m.para == para end)
  ...
end
```
Si hay dos nodos (dos iex independientes), cada uno tiene su propio MessageManager en memoria. Cuando el nodo A guarda un mensaje en `messages.json`, el nodo B no lo sabe. Al recargar del disco, siempre se ven los mensajes más recientes sin importar desde qué nodo se enviaron.

---

### `server.ex` — El loop CLI

**Estructura del loop:**
```elixir
defp loop(user, snode) do
  input = IO.gets(prompt) |> String.trim()

  {new_user, new_snode} = case String.split(input, " ", parts: 2) do
    ["buy_property", id] -> handle({:buy_property, id}, user, snode)
    ["send_message", args] -> handle({:send_message, args}, user, snode)
    # ... más patrones
    _ -> IO.puts("Comando no reconocido."); {user, snode}
  end

  mostrar_mensajes_pendientes()
  loop(new_user, new_snode)  # recursión de cola (tail recursion)
end
```

`String.split(input, " ", parts: 2)` → divide en máximo 2 partes. `"send_message prop001 hola mundo"` se convierte en `["send_message", "prop001 hola mundo"]`. Luego dentro del handler, se hace un segundo split para separar el ID del mensaje.

**El helper rpc:**
```elixir
defp rpc(snode, module, fun, args) do
  if snode == node() do
    apply(module, fun, args)        # llamada local directa
  else
    :rpc.call(snode, module, fun, args)  # llamada remota vía Erlang RPC
  end
end
```

`apply(Module, :funcion, [arg1, arg2])` es el equivalente Elixir de llamar `Module.funcion(arg1, arg2)` dinámicamente.

`:rpc.call/4` de Erlang envía la llamada al nodo remoto, ejecuta la función allí, y devuelve el resultado. Si algo falla devuelve `{:badrpc, reason}`.

---

## 4. CONCEPTOS OTP QUE DEBES DOMINAR

### GenServer — el patrón cliente/servidor

Un GenServer tiene dos partes:

**Parte cliente** (quien llama — puede ser cualquier proceso):
```elixir
GenServer.call(pid_o_nombre, mensaje)   # síncrono, espera respuesta
GenServer.cast(pid_o_nombre, mensaje)   # asíncrono, no espera respuesta
```

**Parte servidor** (el propio GenServer — corre en su proceso):
```elixir
def handle_call(mensaje, _from, state) ->
  # procesa, retorna {:reply, respuesta, nuevo_estado}

def handle_cast(mensaje, state) ->
  # procesa, retorna {:noreply, nuevo_estado}

def handle_info(mensaje, state) ->
  # para mensajes que llegan con send/2 (timers, notificaciones)
  # retorna {:noreply, nuevo_estado}
```

**Cuándo usar call vs cast:**
- `call`: cuando necesitas la respuesta (comprar propiedad, conectar usuario)
- `cast`: cuando no necesitas respuesta (registrar sesión, desregistrar sesión)

### Supervisor — tolerancia a fallos

**`:one_for_one`**: si un hijo falla, solo se reinicia ese hijo.
**`:one_for_all`**: si un hijo falla, se reinician todos los hijos.
**`:rest_for_one`**: si un hijo falla, se reinician ese y todos los que fueron arrancados después.

En este proyecto usamos `:one_for_one` porque los GenServers son independientes.

### Distributed Erlang

Erlang fue diseñado desde el inicio para correr en múltiples nodos. Un nodo es una instancia de la VM de Erlang. La comunicación entre nodos es transparente — enviar un mensaje a un proceso en otro nodo se ve exactamente igual que enviarlo a uno local.

**Cookie**: contraseña compartida que autentica los nodos. Si los cookies no coinciden, los nodos se rechazan mutuamente.

**epmd** (Erlang Port Mapper Daemon): proceso que corre en cada máquina en el puerto 4369. Es el "directorio" de nodos — cuando un nodo quiere conectarse a otro, primero pregunta a epmd qué puerto usa ese nodo.

**PID entre nodos**: `#PID<0.234.0>` en el nodo A es válido desde el nodo B — Erlang sabe en qué nodo vive ese proceso y envía el mensaje correctamente a través de la red.

---

## 5. FLUJOS DE PRUEBA PARA LA SUSTENTACIÓN

### FLUJO 1 — Setup básico (siempre primero)

**Objetivo:** Demostrar arranque y árbol OTP.

```
# Terminal 1 — Servidor
iex --name servidor@TU_IP --cookie inmobiliaria -S mix
Inmobiliaria.Application.start_cli()

# Conectar como vendedor (propietario)
connect vendedor1 pass123 vendedor

# Ver propiedades existentes
list_properties
```

**Punto a resaltar:** Al hacer `-S mix`, automáticamente arrancaron 4 GenServers y se restauraron los procesos de propiedades. Todo sin intervención manual — eso es OTP.

---

### FLUJO 2 — Publicar y comprar (demostrar GenServer de propiedad)

```
# Como vendedor1 (en el servidor)
publish_property tipo=casa modalidad=venta ubicacion=Armenia precio=200000000 habitaciones=3 area=120 banios=2 parking=si descripcion=Casa_amplia_con_garage

# Ver la propiedad recién publicada
list_properties
property_info propXXX   ← usar el ID que se generó

# --- Abrir Terminal 2 o cambiar de usuario ---
connect cliente1 pass456 cliente
connect_node servidor@TU_IP   ← si es otra terminal

# Comprar la propiedad
buy_property propXXX

# Ver el ranking — los puntos deben haber subido
ranking
```

**Punto a resaltar:** `buy_property` llama al proceso `:propXXX` via GenServer.call. Ese proceso verifica el estado (disponible → vendida). Luego PropertyManager persiste, UserManager suma puntos. Son 3 GenServers distintos coordinados por el Server.

---

### FLUJO 3 — Concurrencia (la razón de tener un GenServer por propiedad)

**Objetivo:** Demostrar que dos compras simultáneas no corrompen el estado.

```
# Tener una propiedad disponible: propXXX

# Desde dos clientes diferentes, intentar comprar la misma propiedad
# (hacerlo rápido desde dos terminales o dos sesiones)

# Cliente 1:
buy_property propXXX   → "Compra exitosa."

# Cliente 2 (al mismo tiempo):
buy_property propXXX   → "Error: Propiedad no disponible. Estado actual: vendida"
```

**Explicación técnica:** Los dos mensajes `{:buy, cliente}` llegan a la cola del proceso `:propXXX`. El proceso los atiende uno a uno. El primero compra, cambia estado a `"vendida"`. El segundo llega y el estado ya no es `"disponible"` — recibe error. Sin locks, sin semáforos — la serialización es inherente al modelo de actores.

---

### FLUJO 4 — Reserva temporal con timer automático

```
# Como cliente1
connect cliente1 pass456 cliente
connect_node servidor@TU_IP

# Reservar
reserve_property propXXX
→ "Propiedad propXXX reservada por 30 minutos."

# Intentar comprar como otro cliente (debe fallar)
# (cambiar a cliente2)
connect cliente2 pass789 cliente
buy_property propXXX
→ "Error: Propiedad reservada por 'cliente1'. No disponible."

# El cliente que reservó SÍ puede comprar
connect cliente1 pass456 cliente
buy_property propXXX
→ "Compra exitosa."

# O cancelar la reserva
cancel_reservation propXXX
→ "Reserva cancelada."
```

**Punto a resaltar:** El timer usa `Process.send_after(self(), :expire_reservation, 1_800_000)`. Después de 30 minutos, el proceso `:propXXX` recibe el mensaje `:expire_reservation` en su `handle_info` y restaura el estado automáticamente, sin que ningún usuario lo pida.

---

### FLUJO 5 — Mensajería en tiempo real

**Objetivo:** Demostrar notificación en tiempo real entre procesos.

```
# Terminal 1 — Vendedor conectado y esperando
connect vendedor1 pass123 vendedor
connect_node servidor@TU_IP

# Terminal 2 — Cliente envía mensaje
connect cliente1 pass456 cliente
connect_node servidor@TU_IP
send_message propXXX Hola_me_interesa_la_casa

# En Terminal 1, después del siguiente comando que escriba vendedor1,
# aparece automáticamente:
╔══ MENSAJE NUEVO ══════════════════════════╗
  De: cliente1  |  Propiedad: propXXX
  "Hola me interesa la casa"
╚═══════════════════════════════════════════╝

# Vendedor responde
reply_message propXXX cliente1 Claro_te_espero_el_sabado

# Ver historial
property_messages propXXX
my_messages
```

**Punto a resaltar:** El PID del proceso CLI de vendedor1 está registrado en `MessageManager.online`. Cuando cliente1 envía el mensaje, MessageManager hace `send(pid_vendedor1, {:new_message, msg})` — envío directo al proceso. En el siguiente ciclo del loop, `mostrar_mensajes_pendientes()` con `receive after 0` detecta el mensaje en el buzón y lo imprime.

---

### FLUJO 6 — Distribución entre nodos (el más importante para la sustentación)

**Objetivo:** Demostrar que el sistema funciona distribuido.

```
# --- PC/Terminal Servidor ---
iex --name servidor@192.168.1.20 --cookie inmobiliaria -S mix
Inmobiliaria.Application.start_cli()
connect vendedor1 pass123 vendedor
publish_property tipo=apartamento modalidad=arriendo ubicacion=Pereira precio=1500000 habitaciones=2 area=65 banios=1

# --- PC/Terminal Cliente ---
iex --name cliente1@192.168.1.X --cookie inmobiliaria -S mix
Inmobiliaria.Application.start_cli()
connect_node servidor@192.168.1.20

# El prompt cambia: [cliente1@cliente [→servidor@192.168.1.20]]>
# TODAS las operaciones ahora van al servidor remoto

connect cliente1 pass456 cliente
list_properties          → ve las propiedades del servidor
rent_property propXXX    → arrienda en el servidor remoto
ranking                  → ve el ranking del servidor (con puntos actualizados)
```

**Punto a resaltar:** Después de `connect_node`, el `snode` del loop cambia al nodo remoto. Cada comando llama `rpc(snode, ...)` que usa `:rpc.call/4` de Erlang. La ejecución real ocurre en el servidor remoto — el nodo cliente solo muestra los resultados. Es transparente para el usuario.

---

### FLUJO 7 — Arrendador (demostrar los tres roles)

```
# Arrendador publica para arriendo
connect arrendador1 pass123 arrendador
publish_property tipo=apartamento modalidad=arriendo ubicacion=Armenia precio=1200000 habitaciones=2 area=60 banios=1 parking=no amoblado=si

# Cliente arrienda (NO compra — el arrendador publicó arriendo)
connect cliente2 pass789 cliente
rent_property propXXX   → "Arriendo exitoso. +10 puntos."

# ranking arrendadores — ver puntos del arrendador1
ranking arrendadores
```

---

### FLUJO 8 — Filtros y ranking

```
# Publicar varias propiedades con diferentes características

# Filtrar
filter_properties tipo=casa
filter_properties modalidad=arriendo ubicacion=Armenia
filter_properties precio_min=100000 precio_max=500000000

# Ranking por roles
ranking
ranking compradores
ranking vendedores
ranking arrendadores

# Score individual
my_score
```

---

## 6. PREGUNTAS DIFÍCILES QUE PUEDEN HACERTE

---

**P: ¿Por qué hay un GenServer por cada propiedad en lugar de manejarlas todas en PropertyManager?**

R: PropertyManager mantiene el *registro* (lista de todas las propiedades con su estado para consultas y persistencia). Cada `Property` GenServer maneja las *operaciones transaccionales* de esa propiedad específica (comprar, reservar, arrendar). La razón es la concurrencia: si dos clientes intentan comprar `prop001` al mismo tiempo, los dos mensajes van a la cola del proceso `:prop001` y se procesan secuencialmente — solo uno gana. Si manejáramos todo en PropertyManager, ese único proceso sería el cuello de botella de TODAS las propiedades simultáneamente. Al tener un proceso por propiedad, `prop001` y `prop002` pueden procesarse en paralelo sin interferirse.

---

**P: ¿Qué pasa si PropertyManager falla (crash)?**

R: El Supervisor lo reinicia automáticamente (`:one_for_one`). Al reiniciar, su `init/1` recarga el estado desde `properties.json`. No se pierde información porque persistimos después de cada cambio. El DynamicSupervisor y los procesos de Property siguen corriendo sin verse afectados.

---

**P: ¿Por qué usar `handle_call` en lugar de `handle_cast` para comprar una propiedad?**

R: `handle_call` es síncrono — el proceso que llama espera la respuesta. Necesitamos saber si la compra fue exitosa o no para mostrarle el resultado al usuario, actualizar puntos y registrar la operación. Con `handle_cast` (asíncrono) no habría respuesta y no sabríamos si el proceso aceptó la compra. La regla es: si necesitas el resultado → `call`, si es una notificación sin importar el resultado → `cast`.

---

**P: ¿Cómo garantizan que dos nodos no corrompan el JSON al escribir simultáneamente?**

R: Cada nodo tiene su propio GenServer (PropertyManager, UserManager, MessageManager). Las escrituras son locales al nodo — cada nodo escribe en su propia instancia del archivo. En un setup distribuido, la operación se redirige a UN solo nodo servidor via RPC, así que solo ese nodo escribe. No hay escrituras concurrentes desde múltiples nodos al mismo archivo.

---

**P: ¿Por qué el cookie es necesario en Erlang distribuido?**

R: El cookie es un mecanismo de autenticación simple. Antes de establecer una conexión entre dos nodos, cada uno verifica que el otro tiene el mismo cookie. Si no coinciden, la conexión se rechaza. Evita que cualquier nodo Erlang en la red se conecte a tu clúster sin autorización.

---

**P: ¿Qué es `String.to_atom(id)` y por qué puede ser peligroso en producción?**

R: `String.to_atom("prop001")` crea el átomo `:prop001` en la tabla de átomos de la VM de Erlang. Los átomos nunca se recolectan como basura (garbage collected) y hay un límite de ~1 millón de átomos. Si en producción un atacante pudiera crear IDs arbitrarios, podría llenar la tabla de átomos y crashear la VM. Para este proyecto académico es aceptable porque los IDs los genera el sistema (`prop001`, `prop002`, etc.). En producción usaríamos `String.to_existing_atom/1` o `via_tuple` con Registry.

---

**P: ¿Por qué `mostrar_mensajes_pendientes` usa `receive after 0` y no un loop separado?**

R: Un loop separado requeriría otro proceso, coordinación de PIDs y comunicación entre procesos. Con `receive after 0` aprovechamos que el proceso CLI ya existe y tiene un buzón (mailbox). El `after 0` hace el receive no-bloqueante: si hay mensajes los procesa, si no hay continúa inmediatamente. Es más simple y aprovecha la arquitectura de actores de Erlang sin crear complejidad innecesaria.

---

**P: ¿Por qué recargan messages.json del disco en cada consulta?**

R: Porque puede haber múltiples nodos (instancias de la VM) corriendo simultáneamente, cada uno con su propio MessageManager en memoria. Si el nodo A envía un mensaje y lo guarda en `messages.json`, el nodo B no se entera automáticamente (no compartimos memoria entre VMs). Al recargar del disco en cada consulta, garantizamos que el usuario siempre ve el estado más reciente sin importar desde qué nodo se enviaron los mensajes.

---

**P: ¿Qué es la recursión de cola (tail recursion) en el loop del CLI?**

R: El loop está implementado como recursión:
```elixir
defp loop(user, snode) do
  # ... procesar comando ...
  loop(new_user, new_snode)  # ← última expresión: tail call
end
```
En Elixir/Erlang, cuando la llamada recursiva es la **última** operación de una función, el compilador la optimiza para no apilar un nuevo frame en la pila — en lugar de eso, reutiliza el frame actual. Esto permite que el loop corra indefinidamente sin desbordamiento de pila (stack overflow), por eso el servidor puede estar horas corriendo.

---

## RESUMEN RÁPIDO PARA ACORDARSE ANTES DE ENTRAR

| Pregunta | Respuesta rápida |
|---|---|
| ¿Cuántos GenServers hay? | 4 fijos + 1 por cada propiedad publicada |
| ¿Por qué un proceso por propiedad? | Concurrencia aislada — dos compras simultáneas no se interfieren |
| ¿Qué hace DynamicSupervisor? | Crear/destruir procesos Property en tiempo de ejecución |
| ¿Cómo funciona el tiempo real? | PID del CLI registrado en MessageManager → send directo → receive after 0 |
| ¿Cómo funciona RPC? | connect_node cambia snode → rpc usa :rpc.call/4 de Erlang |
| ¿Qué garantiza el cookie? | Autenticación entre nodos Erlang |
| ¿Cómo persiste? | JSON.encode!/decode! en cada escritura, recarga al arrancar |
| ¿Qué pasa si un GenServer falla? | El Supervisor lo reinicia, recarga estado del JSON |
| ¿Por qué no stack overflow en el loop? | Tail recursion — Erlang optimiza el último call |
| ¿Cuándo usar call vs cast? | Call si necesitas respuesta, cast si es notificación |
