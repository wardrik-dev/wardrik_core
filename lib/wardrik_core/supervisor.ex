defmodule WardrikCore.Supervisor do
  @moduledoc """
  Runs WardrikCore under the host application's tree. Start it after the
  store its backend needs, `:backend` is required.

      children = [
        {EKV, name: :my_ekv, data_dir: "/var/lib/my_app/store", cluster_size: 1},
        {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :my_ekv}}
      ]
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Keyword.fetch!(opts, :backend)

    durable_opts =
      [prefix: "wardrik/"]
      |> Keyword.merge(opts)
      |> Keyword.put(:name, WardrikCore.DurableServer)

    children = [
      {Task.Supervisor, name: WardrikCore.TaskSupervisor},
      {DurableServer.Supervisor, durable_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
