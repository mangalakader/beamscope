defmodule Beamscope.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Beamscope.TaskSupervisor},
      {DynamicSupervisor, name: Beamscope.Embeddings.ServingSupervisor, strategy: :one_for_one},
      Beamscope.Callgraph.Store,
      Beamscope.Search.Store,
      Beamscope.Embeddings
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beamscope.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
