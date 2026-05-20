defmodule Inmobiliaria.Supervisor do
  use DynamicSupervisor

  @moduledoc """
  DynamicSupervisor encargado de gestionar los procesos
  de cada propiedad publicada en el sistema.
  Cada propiedad corre como un proceso independiente bajo este supervisor.
  """

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia un proceso hijo para una propiedad específica.
  Recibe el mapa de datos de la propiedad.
  """
  def start_property(property_data) do
    child_spec = {Inmobiliaria.Property, property_data}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Detiene el proceso de una propiedad dado su PID.
  """
  def stop_property(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Lista todos los procesos de propiedades activos actualmente.
  """
  def list_properties do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
