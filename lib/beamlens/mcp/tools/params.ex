defmodule Beamlens.MCP.Tools.Params do
  @moduledoc """
  Fetches a validated tool param by name, regardless of whether Peri/Hermes
  handed the executor a string-keyed or atom-keyed map — not documented
  either way, so this is defensive rather than assumed.
  """

  @spec get(map(), String.t()) :: term()
  def get(params, key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  end
end
