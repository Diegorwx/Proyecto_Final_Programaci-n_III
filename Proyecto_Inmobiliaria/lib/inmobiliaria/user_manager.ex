defmodule Inmobiliaria.UserManager do
  use GenServer

  @moduledoc """
  Gestión de usuarios del sistema: registro, login, puntajes y ranking.
  Corre como GenServer para serializar escrituras y eliminar condiciones de carrera.
  Persiste datos en formato JSON (data/users.json).

  Campos de cada usuario: username, rol, password, puntaje
  Roles válidos: "cliente", "vendedor", "arrendador"
  """

  @users_file "data/users.json"
  @valid_roles ["cliente", "vendedor", "arrendador"]

  # ---- ARRANQUE ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ---- API PÚBLICA ----

  def connect(username, password, rol, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:connect, username, password, rol})
  end

  def get_user(username, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:get_user, username})
  end

  def add_points(username, puntos, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:add_points, username, puntos})
  end

  def ranking(node \\ node()) do
    GenServer.call({__MODULE__, node}, :ranking)
  end

  def ranking_by_rol(rol, node \\ node()) do
    GenServer.call({__MODULE__, node}, {:ranking_by_rol, rol})
  end

  # ---- CALLBACKS GENSERVER ----

  @impl true
  def init(:ok) do
    {:ok, load_users()}
  end

  @impl true
  def handle_call({:connect, username, password, rol}, _from, users) do
    case Enum.find(users, fn u -> u.username == username end) do
      nil ->
        if rol not in @valid_roles do
          {:reply, {:error, "Rol inválido. Válidos: #{Enum.join(@valid_roles, ", ")}"}, users}
        else
          new_user = %{username: username, rol: rol, password: password, puntaje: 0}
          new_users = [new_user | users]
          save_users(new_users)
          {:reply, {:ok, new_user}, new_users}
        end

      user ->
        if user.password == password do
          {:reply, {:ok, user}, users}
        else
          {:reply, {:error, "Contraseña incorrecta."}, users}
        end
    end
  end

  @impl true
  def handle_call({:get_user, username}, _from, users) do
    case Enum.find(users, fn u -> u.username == username end) do
      nil  -> {:reply, {:error, "Usuario '#{username}' no encontrado."}, users}
      user -> {:reply, {:ok, user}, users}
    end
  end

  @impl true
  def handle_call({:add_points, username, puntos}, _from, users) do
    updated = Enum.map(users, fn u ->
      if u.username == username, do: Map.put(u, :puntaje, u.puntaje + puntos), else: u
    end)
    save_users(updated)
    {:reply, {:ok, puntos}, updated}
  end

  @impl true
  def handle_call(:ranking, _from, users) do
    case users do
      [] ->
        {:reply, {:error, "No hay usuarios registrados."}, users}
      _ ->
        ranked =
          users
          |> Enum.sort_by(& &1.puntaje, :desc)
          |> Enum.with_index(1)
          |> Enum.map(fn {u, pos} ->
            %{posicion: pos, username: u.username, rol: u.rol, puntaje: u.puntaje}
          end)
        {:reply, {:ok, ranked}, users}
    end
  end

  @impl true
  def handle_call({:ranking_by_rol, rol}, _from, users) do
    filtrados =
      users
      |> Enum.filter(fn u -> u.rol == rol end)
      |> Enum.sort_by(& &1.puntaje, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {u, pos} ->
        %{posicion: pos, username: u.username, rol: u.rol, puntaje: u.puntaje}
      end)

    case filtrados do
      [] -> {:reply, {:error, "No hay usuarios con rol '#{rol}'."}, users}
      _  -> {:reply, {:ok, filtrados}, users}
    end
  end

  # ---- PERSISTENCIA JSON ----

  defp load_users do
    case File.read(@users_file) do
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

  defp save_users(users) do
    File.write(@users_file, JSON.encode!(users))
  end

  # Convierte claves string (que devuelve JSON.decode!) a átomos
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end
