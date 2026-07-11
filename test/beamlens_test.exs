defmodule BeamlensTest do
  use ExUnit.Case
  doctest Beamlens

  test "greets the world" do
    assert Beamlens.hello() == :world
  end
end
