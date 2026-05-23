# Descripción del Proyecto: Sistema de Inmobiliaria Virtual en Elixir

## Contexto General

Sistema multiusuario de inmobiliaria virtual implementado en Elixir usando OTP (Open Telecom Platform). Múltiples usuarios se conectan desde CLI en tiempo real. Hay tres roles: **cliente**, **vendedor** y **arrendador**. Cada propiedad publicada corre como un proceso independiente (GenServer). El sistema maneja concurrencia, supervisión de procesos, persistencia en JSON, mensajería en tiempo real entre usuarios, ranking de actividad y distribución entre nodos Erlang.

---

## Módulos del Sistema (archivos en `lib/inmobiliaria/`)

### 1. `Inmobiliaria.Application` (`application.ex`)
- Punto de entrada OTP. Implementa el behaviour `Application`.
- En `start/2` arranca el árbol de supervisión principal llamado `Inmobiliaria.MainSupervisor` (un `Supervisor` estático con estrategia `:one_for_one`).
- Sus cuatro hijos son: `Inmobiliaria.Supervisor`, `Inmobiliaria.UserManager`, `Inmobiliaria.PropertyManager`, `Inmobiliaria.MessageManager`.
- Después de arrancar el árbol, llama a `restore_property_processes/0`, que consulta `PropertyManager` para obtener todas las propiedades persistidas y lanza un proceso `Inmobiliaria.Property` (GenServer) por cada una via `Inmobiliaria.Supervisor.start_property/1`.
- Expone `start_cli/0` que delega a `Inmobiliaria.Server.start/0`.

### 2. `Inmobiliaria.Supervisor` (`supervisor.ex`)
- Implementa `DynamicSupervisor` con estrategia `:one_for_one`.
- Se registra con el nombre `Inmobiliaria.Supervisor`.
- Función pública `start_property/1`: recibe un mapa de datos de propiedad y llama a `DynamicSupervisor.start_child/2` con el child spec `{Inmobiliaria.Property, property_data}`.

### 3. `Inmobiliaria.UserManager` (`user_manager.ex`)
- GenServer registrado como `Inmobiliaria.UserManager`.
- **Estado interno**: lista de mapas de usuario cargada desde `data/users.json` en `init/1`.
- **Formato de cada usuario** (mapa con claves átomo): `%{username, rol, password, puntaje}`.
- **Roles válidos**: `"cliente"`, `"vendedor"`, `"arrendador"`.
- Todos los métodos públicos aceptan `node \\ node()` para soporte distribuido.
- **API pública**:
  - `connect(username, password, rol, node)` → si el usuario no existe lo registra con puntaje 0; si existe valida la contraseña. Retorna `{:ok, user}` o `{:error, msg}`.
  - `get_user(username, node)` → busca usuario. Retorna `{:ok, user}` o `{:error, msg}`.
  - `add_points(username, puntos, node)` → incrementa el puntaje y persiste. Retorna `{:ok, puntos}`.
  - `ranking(node)` → retorna todos los usuarios ordenados por puntaje descendente con posición.
  - `ranking_by_rol(rol, node)` → igual pero filtrado por rol.
- **Persistencia**: `data/users.json` usando `JSON.encode!/1` y `JSON.decode!/1` (Elixir 1.18 built-in). Al cargar, las claves string se convierten a átomos con `String.to_atom/1`.

### 4. `Inmobiliaria.PropertyManager` (`property_manager.ex`)
- GenServer registrado como `Inmobiliaria.PropertyManager`.
- **Estado interno**: lista de mapas de propiedad cargada desde `data/properties.json` en `init/1`.
- **Formato de cada propiedad** (mapa con claves átomo): `%{id, tipo, modalidad, ubicacion, precio, habitaciones, area, banios, parking, amoblado, descripcion, estado, propietario}`.
- **Roles que pueden publicar**: `"vendedor"`, `"arrendador"`.
- Todos los métodos públicos aceptan `node \\ node()` para soporte distribuido.
- **API pública**:
  - `publish(propietario, rol, tipo, modalidad, ubicacion, precio, habitaciones, area, banios, parking, amoblado, descripcion, node)` → valida rol, valida campos obligatorios, valida ubicación via `Location.valid?/1`, genera ID secuencial, crea propiedad con estado `"disponible"`, persiste en JSON y llama `Supervisor.start_property/1`. Retorna `{:ok, property}` o `{:error, msg}`.
  - `list_all(node)` → retorna todas las propiedades.
  - `filter(filters, node)` → filtra propiedades disponibles por tipo, modalidad, ubicación, precio_min, precio_max.
  - `get(id, node)` → busca propiedad por ID.
  - `update_estado(id, nuevo_estado, node)` → actualiza estado y persiste. Al pasar a `"disponible"` limpia campos de reserva.
- **Persistencia**: `data/properties.json`. Al guardar, elimina campos volátiles (`timer_ref`, `reservado_por`, `reservado_hasta`) y normaliza propiedades reservadas a `"disponible"` para que al reiniciar no queden bloqueadas.
- Aplica defaults para campos nuevos en propiedades antiguas al cargar (`banios: 1`, `parking: false`, `amoblado: false`, `descripcion: ""`).

### 5. `Inmobiliaria.Property` (`property.ex`)
- GenServer que representa **una propiedad individual**. Cada propiedad publicada tiene su propio proceso.
- Registrado con nombre atómico derivado del ID: `String.to_atom(property_data.id)` (ej: `:prop001`).
- **Estado interno**: mapa con todos los campos de la propiedad más campos de reserva.
- **API pública** (todos aceptan `node \\ node()`):
  - `get(id, node)` → retorna estado actual.
  - `buy(id, cliente, node)` → si `estado == "disponible"` o si el cliente es quien reservó, cambia a `"vendida"`. Retorna `{:ok, prop}` o `{:error, msg}`.
  - `rent(id, cliente, node)` → igual pero cambia a `"arrendada"`.
  - `reserve(id, cliente, node)` → si disponible, cambia a `"reservada"`, guarda `reservado_por`, `reservado_hasta` (30 minutos desde ahora), lanza timer con `Process.send_after(self(), :expire_reservation, 30*60*1000)`. Retorna `{:ok, prop}` o `{:error, msg}`.
  - `cancel_reservation(id, cliente, node)` → cancela reserva si el cliente es quien la hizo, cancela el timer y restaura estado a `"disponible"`.
  - `update(id, campos, node)` → `Map.merge` del estado con los campos dados.
- **Expiración automática**: al recibir `handle_info(:expire_reservation, state)`, restaura estado a `"disponible"`, notifica por pantalla y llama `PropertyManager.update_estado`.
- **Concurrencia**: `handle_call` es serial por proceso; dos clientes que intentan comprar simultáneamente solo el primero lo logra.

### 6. `Inmobiliaria.MessageManager` (`message_manager.ex`)
- **GenServer** registrado como `Inmobiliaria.MessageManager` (con estado en memoria).
- **Estado interno**: `%{messages: [...], online: %{username => pid}}`.
  - `messages`: lista de mapas de mensajes cargada desde `data/messages.json` en `init/1`.
  - `online`: mapa de usuarios conectados con su PID del proceso CLI (para notificaciones en tiempo real).
- Todos los métodos públicos aceptan `node \\ node()` para soporte distribuido.
- **API pública**:
  - `register_session(username, pid, node)` → registra el PID del proceso CLI del usuario para recibir notificaciones. Cast asíncrono.
  - `unregister_session(username, node)` → elimina el PID al desconectarse. Cast asíncrono.
  - `send_message(de, propiedad_id, mensaje, node)` → obtiene propietario via `PropertyManager.get/1`, crea mensaje con fecha actual, lo añade al estado, persiste en JSON, y si el destinatario está en `online` le envía `send(pid, {:new_message, msg})`. Retorna `{:ok, msg}` o `{:error, msg}`.
  - `reply_message(de, propiedad_id, para, mensaje, node)` → solo el propietario de la propiedad puede responder. Mismo flujo que `send_message`. Retorna `{:ok, msg}` o `{:error, msg}`.
  - `get_messages_for(para, node)` → recarga desde JSON (para ver mensajes de otras sesiones), filtra por `m.para == para`. Retorna `{:ok, list}` o `{:error, "No tienes mensajes."}`.
  - `get_messages_by_property(propiedad_id, node)` → recarga desde JSON, filtra por `m.propiedad_id`. Retorna `{:ok, list}` o `{:error, msg}`.
- **Persistencia**: `data/messages.json`. Siempre recarga del disco en las consultas para garantizar visibilidad de mensajes enviados desde otras sesiones/nodos.
- **Formato de mensaje** (mapa con claves átomo): `%{fecha, de, para, propiedad_id, mensaje}`.

### 7. `Inmobiliaria.Location` (`location.ex`)
- Módulo funcional (sin estado en proceso, lee archivo directo).
- **API pública**:
  - `valid?(ubicacion)` → compara case-insensitive contra la lista. Retorna `{:ok, ubicacion_original}` o `{:error, msg}`.
  - `list_locations()` → retorna la lista de ubicaciones o error si está vacía.
- **Ubicaciones**: Armenia, Pereira, Manizales, Calarcá, Montenegro, Quimbaya, La Tebaida, Circasia, Filandia, Salento.
- **Persistencia**: `data/locations.dat`, una ubicación por línea (texto plano, sin cambios).

### 8. `Inmobiliaria.Server` (`server.ex`)
- Módulo funcional (sin proceso propio). Contiene el bucle CLI.
- `start/0` → imprime bienvenida y llama a `loop(nil, node())`.
- `loop(user, snode)` → bucle recursivo. Lee línea de stdin. Hace pattern matching del comando sobre `String.split(input, " ", parts: 2)`. Llama a `handle/3` que retorna `{new_user, new_snode}`. Después de cada comando llama `mostrar_mensajes_pendientes/0`. Vuelve a llamar `loop/2`.
- `snode` es el nodo al que se redirigen las operaciones (por defecto `node()`, cambia con `connect_node`).
- `rpc(snode, module, fun, args)` → si `snode == node()` usa `apply/3`, si no usa `:rpc.call/4` de Erlang.
- **Constantes**: `@puntos_cliente = 10`, `@puntos_propietario = 15`.
- **Prompt**: `[username@rol]>` o `[username@rol [→nodo]]>` si hay nodo remoto.
- **Comandos implementados**:
  - `help` → muestra lista de comandos.
  - `connect <username> <password> <rol>` → llama `UserManager.connect/4`, registra sesión en `MessageManager`.
  - `disconnect` → desregistra sesión en `MessageManager`, pone user en nil.
  - `list_properties` → llama `PropertyManager.list_all/1`.
  - `list_locations` → llama `Location.list_locations/0` via rpc.
  - `filter_properties <filtros>` → parsea `clave=valor` y llama `PropertyManager.filter/2`.
  - `publish_property <datos>` → solo vendedor/arrendador. Parsea `tipo=X modalidad=X ubicacion=X precio=X habitaciones=X area=X banios=X parking=si/no amoblado=si/no descripcion=texto_con_guiones_bajos`. Llama `PropertyManager.publish/13`.
  - `property_info <id>` → muestra ficha completa de la propiedad incluyendo descripción, baños, parking, amoblado. Si está reservada muestra quién la reservó y hasta cuándo.
  - `buy_property <id>` → solo clientes. Llama `Property.buy/3` via rpc → si OK llama `PropertyManager.update_estado`, `UserManager.add_points` para cliente (+10) y propietario (+15), y `log_operation/4`. Maneja `{:badrpc, _}`.
  - `rent_property <id>` → igual que buy pero para arriendo. Estado final: `"arrendada"`. Maneja `{:badrpc, _}`.
  - `reserve_property <id>` → solo clientes. Llama `Property.reserve/3` via rpc, actualiza estado en `PropertyManager`. Maneja `{:badrpc, _}`.
  - `cancel_reservation <id>` → llama `Property.cancel_reservation/3` via rpc, restaura estado. Maneja `{:badrpc, _}`.
  - `send_message <id> <mensaje>` → llama `MessageManager.send_message/4` via rpc.
  - `reply_message <id> <cliente> <mensaje>` → llama `MessageManager.reply_message/5` via rpc (solo propietario).
  - `my_messages` → llama `MessageManager.get_messages_for/2` via rpc.
  - `property_messages <id>` → llama `MessageManager.get_messages_by_property/2` via rpc.
  - `my_score` → llama `UserManager.get_user/2`.
  - `ranking` → llama `UserManager.ranking/1`.
  - `ranking <rol>` → llama `UserManager.ranking_by_rol/2`. Acepta aliases: `compradores`→`cliente`, `vendedores`→`vendedor`, `arrendadores`→`arrendador`.
  - `connect_node <nodo@host>` → llama `Node.connect/1`. Si tiene éxito, redirige la sesión del usuario al nuevo nodo en `MessageManager`. Cambia `snode`.
  - `disconnect_node` → restaura `snode` a `node()`.
  - `exit` → llama `exit(:normal)`.
- `mostrar_mensajes_pendientes/0` → `receive` con `after 0` para revisar el buzón del proceso sin bloquear. Si hay `{:new_message, msg}`, imprime el banner de MENSAJE NUEVO y se llama recursivamente hasta vaciar el buzón.
- `log_operation/4` → escribe en `data/results.log` via rpc: `fecha; cliente=X; responsable=X; propiedad=X; operacion=X; ubicacion=X; precio=X; status=Completada`.

---

## Archivos de Persistencia (`data/`)

| Archivo | Formato | Contenido |
|---|---|---|
| `users.json` | JSON array de objetos | Usuarios con username, rol, password, puntaje |
| `properties.json` | JSON array de objetos | Propiedades con todos sus campos |
| `messages.json` | JSON array de objetos | Mensajes con fecha, de, para, propiedad_id, mensaje |
| `results.log` | Texto plano, append | Una operación por línea: `fecha; cliente=X; responsable=X; propiedad=X; operacion=X; ubicacion=X; precio=X; status=Completada` |
| `locations.dat` | Texto plano | Una ubicación por línea |

---

## Árbol de Supervisión OTP

```
Inmobiliaria.MainSupervisor  (Supervisor estático, estrategia: :one_for_one)
├── Inmobiliaria.Supervisor       (DynamicSupervisor, estrategia: :one_for_one)
│   ├── :prop001                  (Inmobiliaria.Property — GenServer)
│   ├── :prop002                  (Inmobiliaria.Property — GenServer)
│   └── :propN...                 (Inmobiliaria.Property — GenServer)
├── Inmobiliaria.UserManager      (GenServer)
├── Inmobiliaria.PropertyManager  (GenServer)
└── Inmobiliaria.MessageManager   (GenServer)
```

Los procesos de propiedades se crean dinámicamente al publicar una propiedad y se restauran al arrancar la aplicación leyendo `properties.json`.

---

## Soporte Distribuido (Nodos Erlang)

El sistema soporta múltiples nodos Erlang conectados entre sí:

- **Arranque con nombre**: `iex --name servidor@192.168.1.x --cookie inmobiliaria -S mix`
- **Conexión desde CLI**: `connect_node servidor@192.168.1.x`
- Una vez conectado, todas las operaciones (publish, buy, rent, mensajes, etc.) se redirigen al nodo servidor via `:rpc.call/4`.
- La sesión del usuario se re-registra en el `MessageManager` del nodo destino para que las notificaciones en tiempo real sigan funcionando.
- `Property.buy/3`, `Property.rent/3`, etc. usan `GenServer.call({String.to_atom(id), node}, ...)` para contactar el proceso de la propiedad en el nodo remoto.
- Los handlers de `buy_property`, `rent_property`, `reserve_property` y `cancel_reservation` manejan `{:badrpc, _}` para mostrar error amigable si la propiedad no existe en el nodo remoto.

---

## Mensajería en Tiempo Real

- Al conectarse, el proceso CLI llama `MessageManager.register_session(username, self(), snode)` que guarda el PID del proceso loop en el mapa `online` del GenServer.
- Al enviar un mensaje, `MessageManager` verifica si el destinatario está en `online` y le envía `send(pid, {:new_message, msg})` directamente al proceso.
- Después de cada comando en el loop, `mostrar_mensajes_pendientes/0` revisa el buzón con `receive after 0` y muestra un banner si hay mensajes nuevos.
- `get_messages_for` y `get_messages_by_property` recargan desde JSON para garantizar que se vean mensajes enviados desde otras sesiones o nodos.

---

## Flujo de una Compra (secuencia de mensajes entre procesos)

1. Usuario CLI escribe `buy_property prop001`
2. `Server.loop/2` hace pattern match y llama `handle({:buy_property, "prop001"}, user, snode)`
3. `Server` llama `rpc(snode, Inmobiliaria.Property, :buy, ["prop001", "ana"])` → internamente hace `GenServer.call({:prop001, snode}, {:buy, "ana"})`
4. El proceso `:prop001` en `snode` recibe el call. Si `estado == "disponible"` → cambia estado a `"vendida"`, retorna `{:ok, nuevo_estado}`. Si no, retorna `{:error, msg}`. Si el proceso no existe, retorna `{:badrpc, ...}`.
5. Si OK: `Server` llama `PropertyManager.update_estado("prop001", "vendida", snode)` → actualiza lista interna y persiste en `properties.json`.
6. `Server` llama `UserManager.add_points("ana", 10, snode)` → actualiza puntaje y persiste en `users.json`.
7. `Server` llama `UserManager.add_points("carlos", 15, snode)` → igual para el propietario.
8. `Server` llama `log_operation/4` → escribe línea en `results.log`.
9. `Server` imprime confirmación al CLI y vuelve al `loop/2`.

---

## Flujo de Envío de Mensaje

1. Cliente escribe `send_message prop001 Hola me interesa la propiedad`
2. `Server` llama `rpc(snode, MessageManager, :send_message, ["ana", "prop001", "Hola..."])`
3. `MessageManager` llama `PropertyManager.get("prop001")` para obtener el propietario (`"carlos"`).
4. Crea `%{fecha: ..., de: "ana", para: "carlos", propiedad_id: "prop001", mensaje: "Hola..."}`.
5. Añade al estado y persiste en `messages.json`.
6. Si `"carlos"` está en `online`, hace `send(pid_carlos, {:new_message, msg})`.
7. En el próximo ciclo del loop de Carlos, `mostrar_mensajes_pendientes/0` detecta el mensaje y muestra el banner.

---

## Flujo de Reserva Temporal

1. Cliente escribe `reserve_property prop001`
2. `Server` llama `rpc(snode, Property, :reserve, ["prop001", "ana"])`
3. El proceso `:prop001` cambia estado a `"reservada"`, guarda `reservado_por: "ana"`, lanza `Process.send_after(self(), :expire_reservation, 1_800_000)`.
4. `Server` llama `PropertyManager.update_estado("prop001", "reservada", snode)`.
5. Después de 30 minutos, `:prop001` recibe `:expire_reservation`, restaura estado a `"disponible"` y llama `PropertyManager.update_estado`.
6. El cliente puede cancelar antes con `cancel_reservation prop001`.

---

## Modelo de Datos

### Entidades

**Usuario**
- `username` (string, clave primaria)
- `rol` (string: `cliente` | `vendedor` | `arrendador`)
- `password` (string)
- `puntaje` (integer, default 0)

**Propiedad**
- `id` (string, clave primaria, formato: `propXXX`)
- `tipo` (string: `casa` | `apartamento` | `oficina` | `lote`)
- `modalidad` (string: `venta` | `arriendo`)
- `ubicacion` (string)
- `precio` (integer)
- `habitaciones` (integer)
- `area` (float)
- `banios` (integer, default 1)
- `parking` (boolean, default false)
- `amoblado` (boolean, default false)
- `descripcion` (string, default "")
- `estado` (string: `disponible` | `vendida` | `arrendada` | `reservada`)
- `propietario` (string, referencia a Usuario.username)

**Mensaje**
- `fecha` (string, date ISO)
- `de` (string, referencia a Usuario.username)
- `para` (string, referencia a Usuario.username — propietario de la propiedad)
- `propiedad_id` (string, referencia a Propiedad.id)
- `mensaje` (string)

**Operacion** (registro inmutable en `results.log`)
- `fecha` (string, date)
- `cliente` (string)
- `responsable` (string)
- `propiedad_id` (string)
- `operacion` (string: `compra` | `arriendo`)
- `ubicacion` (string)
- `precio` (integer)
- `status` (string: `Completada`)

### Relaciones
- Un Usuario (vendedor/arrendador) publica muchas Propiedades — **1:N**
- Una Propiedad pertenece a un Usuario propietario — **N:1**
- Un Usuario (cliente) genera muchas Operaciones — **1:N**
- Un Usuario (cliente) envía muchos Mensajes — **1:N**
- Un Mensaje está asociado a una Propiedad — **N:1**
- Un Mensaje tiene un destinatario (propietario de la propiedad) — **N:1**

---

## Dependencias entre Módulos

```
Server
  ├── llama → UserManager (connect, get_user, add_points, ranking)
  ├── llama → PropertyManager (list_all, filter, publish, get, update_estado)
  ├── llama → Property (buy, rent, reserve, cancel_reservation, get)
  ├── llama → MessageManager (send_message, reply_message, get_messages_for,
  │                           get_messages_by_property, register_session, unregister_session)
  └── llama → Location (list_locations)

PropertyManager
  ├── llama → Location (valid?)
  └── llama → Supervisor (start_property)

MessageManager
  └── llama → PropertyManager (get — para obtener propietario)

Property
  └── llama → PropertyManager (update_estado — al expirar reserva)

Application
  ├── arranca → MainSupervisor
  │     ├── arranca → Supervisor (DynamicSupervisor)
  │     ├── arranca → UserManager
  │     ├── arranca → PropertyManager
  │     └── arranca → MessageManager
  └── llama → restore_property_processes
        ├── llama → PropertyManager (list_all)
        └── llama → Supervisor (start_property por cada propiedad)

Supervisor (DynamicSupervisor)
  └── gestiona hijos → Property (uno por propiedad)
```

---

## Comandos CLI Completos

```
connect <username> <password> <rol>
disconnect
list_properties
list_locations
filter_properties tipo=X modalidad=X ubicacion=X precio_min=X precio_max=X
publish_property tipo=X modalidad=X ubicacion=X precio=X habitaciones=X area=X banios=X parking=si/no amoblado=si/no descripcion=texto_con_guiones_bajos
property_info <id>
buy_property <id>
rent_property <id>
reserve_property <id>
cancel_reservation <id>
send_message <id> <mensaje>
reply_message <id> <cliente_username> <mensaje>
my_messages
property_messages <id>
my_score
ranking
ranking compradores|vendedores|arrendadores
connect_node <nodo@host>
disconnect_node
exit
```

---

## Prompts Sugeridos para Generar los Diagramas

Pega toda esta descripción en Claude y luego usa uno de estos prompts:

- **OTP Tree**: *"Con base en esta descripción, genera el Diagrama de Árbol de Supervisión OTP en formato Mermaid mostrando todos los procesos, sus tipos (Supervisor, DynamicSupervisor, GenServer) y las relaciones de supervisión."*

- **Diagrama de Secuencia — Compra**: *"Genera el Diagrama de Secuencia en Mermaid para el flujo completo de compra de una propiedad, mostrando los mensajes entre: Usuario CLI, Server, Property (GenServer), PropertyManager, UserManager y el archivo results.log."*

- **Diagrama de Secuencia — Mensajería**: *"Genera el Diagrama de Secuencia en Mermaid para el flujo completo de envío de mensaje en tiempo real: desde que el cliente escribe send_message, pasando por MessageManager, hasta que el propietario ve el banner MENSAJE NUEVO en su CLI."*

- **Diagrama de Secuencia — Reserva**: *"Genera el Diagrama de Secuencia en Mermaid para el flujo de reserva temporal de una propiedad, incluyendo el timer de 30 minutos y la expiración automática."*

- **Modelo de Datos**: *"Genera el Diagrama Entidad-Relación (ER) en Mermaid con todas las entidades, sus atributos y las relaciones entre ellas."*

- **Arquitectura de Módulos**: *"Genera el Diagrama de Arquitectura de Módulos en Mermaid mostrando todos los módulos del sistema y las flechas de dependencia/llamada entre ellos, indicando el tipo de cada módulo (GenServer, DynamicSupervisor, módulo funcional, Application)."*

- **Arquitectura Distribuida**: *"Genera un diagrama en Mermaid mostrando la arquitectura distribuida del sistema: dos o más nodos Erlang, los GenServers en cada nodo, cómo el CLI de un nodo cliente redirige operaciones al nodo servidor via RPC, y cómo funciona la notificación en tiempo real entre nodos."*
