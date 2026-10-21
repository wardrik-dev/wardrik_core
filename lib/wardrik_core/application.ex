defmodule WardrikCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ekv_config = [
    #   name: :durable_ekv,
    #   data_dir: "~/.local/share/wardrik/store/",
    #   cluster_size: 1
    # ]
    #
    children = [
      # {EKV, name: :wardrik_ekv, data_dir: "~/.local/share/wardrik/store/", cluster_size: 1},
      # {DurableServer.Supervisor,
      #  name: WardrikCore.DurableServer,
      #  prefix: "wardrik/",
      #  backend: {DurableServer.Backends.EKVStore, ekv_config}}
    ]

    opts = [strategy: :one_for_one, name: WardrikCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
