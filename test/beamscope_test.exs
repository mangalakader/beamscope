defmodule BeamscopeTest do
  use ExUnit.Case
  doctest Beamscope

  test "greets the world" do
    assert Beamscope.hello() == :world
  end
end
