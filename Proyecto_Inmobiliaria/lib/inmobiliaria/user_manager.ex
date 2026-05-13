defmodule Inmobiliaria.UserManager do
  @moduledoc """
  Gestión de usuarios del sistema: registro, login,
  puntajes y ranking de actividad.
  Los usuarios se persisten en data/users.dat.
  """

  @users_file "data/users.dat"

  # ---- PERSISTENCIA ----

  defp load_users do
    case File.read(@users_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_user/1)

      {:error, _} ->
        []
    end
  end

  defp parse_user(line) do
    [username, rol, password, puntaje] = String.split(line, ";")

    %{
      username: username,
      rol: rol,
      password: password,
      puntaje: String.to_integer(puntaje)
    }
  end

  defp save_users(users) do
    content =
      users
      |> Enum.map(fn u ->
        "#{u.username};#{u.rol};#{u.password};#{u.puntaje}"
      end)
      |> Enum.join("\n")

    File.write(@users_file, content <> "\n")
  end

  # ---- API PÚBLICA ----

  @doc """
  Conecta un usuario al sistema.
  Si no existe lo registra automáticamente.
  Si existe valida la contraseña.
  Retorna {:ok, user} o {:error, mensaje}.
  """
  def connect(username, password, rol) do
    users = load_users()

    case Enum.find(users, fn u -> u.username == username end) do
      nil ->
        register(username, password, rol)

      user ->
        if user.password == password do
          {:ok, user}
        else
          {:error, "Contraseña incorrecta."}
        end
    end
  end

  @doc """
  Registra un nuevo usuario en el sistema.
  Retorna {:ok, user} o {:error, mensaje}.
  """
  def register(username, password, rol) do
    users = load_users()

    already_exists = Enum.any?(users, fn u -> u.username == username end)

    if already_exists do
      {:error, "El usuario '#{username}' ya existe."}
    else
      valid_roles = ["cliente", "vendedor", "arrendador"]

      if rol not in valid_roles do
        {:error, "Rol inválido. Los roles válidos son: #{Enum.join(valid_roles, ", ")}"}
      else
        new_user = %{username: username, rol: rol, password: password, puntaje: 0}
        save_users([new_user | users])
        {:ok, new_user}
      end
    end
  end

  @doc """
  Retorna los datos de un usuario por su username.
  """
  def get_user(username) do
    users = load_users()

    case Enum.find(users, fn u -> u.username == username end) do
      nil -> {:error, "Usuario '#{username}' no encontrado."}
      user -> {:ok, user}
    end
  end

  @doc """
  Suma puntos a un usuario y guarda el resultado.
  """
  def add_points(username, puntos) do
    users = load_users()

    updated =
      Enum.map(users, fn u ->
        if u.username == username do
          Map.put(u, :puntaje, u.puntaje + puntos)
        else
          u
        end
      end)

    save_users(updated)
    {:ok, puntos}
  end

  @doc """
  Muestra el ranking global de usuarios ordenado por puntaje.
  """
  def ranking do
    users = load_users()

    case users do
      [] ->
        {:error, "No hay usuarios registrados."}

      _ ->
        ranked =
          users
          |> Enum.sort_by(fn u -> u.puntaje end, :desc)
          |> Enum.with_index(1)
          |> Enum.map(fn {u, pos} ->
            %{posicion: pos, username: u.username, rol: u.rol, puntaje: u.puntaje}
          end)

        {:ok, ranked}
    end
  end

  @doc """
  Ranking filtrado por rol: "cliente", "vendedor" o "arrendador".
  """
  def ranking_by_rol(rol) do
    users = load_users()

    filtered =
      users
      |> Enum.filter(fn u -> u.rol == rol end)
      |> Enum.sort_by(fn u -> u.puntaje end, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {u, pos} ->
        %{posicion: pos, username: u.username, rol: u.rol, puntaje: u.puntaje}
      end)

    case filtered do
      [] -> {:error, "No hay usuarios con rol '#{rol}'."}
      _ -> {:ok, filtered}
    end
  end
end
