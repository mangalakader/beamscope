defmodule Beamlens.Callgraph.ExtractorTest do
  use ExUnit.Case, async: true

  alias Beamlens.Callgraph.Extractor

  @fixtures Path.join([File.cwd!(), "priv", "fixtures"])

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "Erlang extraction" do
    test "resolves a call hidden behind a macro (the core differentiator over tree-sitter)" do
      {_defs, edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))

      # ?BACKEND_MODULE(Host) expands to gen_mod:get_module_opt(...) — only
      # visible because :epp fully expands macros during parsing. A
      # tree-sitter-based extractor only ever sees the raw ?MACRO token.
      assert Enum.any?(edges, fn e ->
               e.caller_name == "get_user" and e.callee_module == "gen_mod" and
                 e.callee_name == "get_module_opt"
             end)
    end

    test "marks a call through a variable module as unresolved (\"?\")" do
      {_defs, edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))

      # Backend:get_user(...) — Backend is a runtime variable, not a
      # literal atom, so the target module can't be statically resolved.
      assert Enum.any?(edges, fn e ->
               e.caller_name == "get_user" and e.callee_module == "?" and
                 e.callee_name == "get_user"
             end)
    end

    test "resolves a direct remote call to its literal module" do
      {_defs, edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))

      assert Enum.any?(edges, fn e ->
               e.caller_name == "start" and e.callee_module == "gen_mod" and
                 e.callee_name == "start_backend_module"
             end)
    end

    test "derives the module name from the -module attribute" do
      {defs, _edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))

      assert Enum.all?(defs, &(&1.module == "mod_fake_backend"))
    end
  end

  describe "Elixir extraction" do
    test "resolves a local call within the same module" do
      {_defs, edges} = Extractor.extract_from_file(fixture("fake_session.ex"))

      assert [
               %{
                 caller_module: "Beamlens.FakeSession",
                 caller_name: "resume",
                 callee_module: "Beamlens.FakeSession",
                 callee_name: "verify"
               }
             ] = edges
    end

    test "qualifies defs with their full nested module path" do
      {defs, _edges} = Extractor.extract_from_file(fixture("fake_session.ex"))

      assert Enum.any?(defs, &(&1.module == "Beamlens.FakeSession.Nested" and &1.name == "ping"))
    end

    test "does not record special forms or operators as calls" do
      {_defs, edges} = Extractor.extract_from_file(fixture("fake_session.ex"))

      # verify/2's guard (`when is_binary(token)`) and its body (a bare
      # variable) produce no real calls; nothing here should show up.
      refute Enum.any?(edges, &(&1.caller_name == "verify"))
    end
  end

  describe "unsupported/unparseable files" do
    test "returns empty defs/edges for a file with no function forms" do
      assert Extractor.extract_from_file(fixture("empty_comment_only.hrl")) == {[], []}
    end

    test "returns empty defs/edges on a fatal parse failure" do
      assert Extractor.extract_from_file(fixture("broken_syntax.ex")) == {[], []}
    end

    test "a macro-generated def name (`def unquote(name)(...)`) doesn't crash the whole file" do
      {defs, _edges} = Extractor.extract_from_file(fixture("unquoted_def_name.ex"))

      assert Enum.any?(defs, &(&1.name == "normal_fun"))
      assert Enum.any?(defs, &(&1.name == "?"))
    end
  end
end
