defmodule Beamlens.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Beamlens.TaskSupervisor},
      {DynamicSupervisor, name: Beamlens.Embeddings.ServingSupervisor, strategy: :one_for_one},
      Beamlens.Callgraph.Store,
      Beamlens.Search.Store,
      Beamlens.Embeddings
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beamlens.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
