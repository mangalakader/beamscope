defmodule Beamscope.FakeSession do
  @moduledoc "Synthetic fixture standing in for a real session-handling module."

  def resume(session_id, token), do: verify(session_id, token)

  defp verify(session_id, token) when is_binary(token) do
    session_id
  end

  def close(session_id) do
    :ok
  end

  defmodule Nested do
    def ping do
      :pong
    end
  end
end
