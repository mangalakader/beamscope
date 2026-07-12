defmodule Beamscope.MCP.Tool do
  @moduledoc """
  Behaviour for an MCP tool: a name, description, JSON Schema for its
  input, and a call function. Deliberately plain — no macro DSL, no
  schema-validation library — since `Beamscope.MCP.Protocol` does the only
  validation actually needed (required-key presence) itself.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback call(params :: map()) :: {:ok, map()} | {:error, String.t()}
end
