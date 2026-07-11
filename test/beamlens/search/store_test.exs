defmodule Beamlens.Search.StoreTest do
  use ExUnit.Case, async: false

  alias Beamlens.Search.Store

  test "indexed?/1 is false for a repo that was never queried" do
    refute Store.indexed?("priv/fixtures/never_queried_search_repo")
  end
end
