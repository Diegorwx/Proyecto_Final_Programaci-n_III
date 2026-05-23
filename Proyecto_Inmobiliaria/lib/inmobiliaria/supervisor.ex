defmodule Inmobiliaria.Supervisor do
  use DynamicSupervisor

  @moduledoc """
  DynamicSupervisor encargado de gestionar los procesos de cada propiedad.
  Se registra con :global para ser alcanzable desde cualquier nodo conectado.
  """

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_property(property_data) do
    child_spec = {Inmobiliaria.Property, property_data}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def stop_property(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def list_properties do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
