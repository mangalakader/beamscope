defmodule Beamscope.Callgraph.Extractor do
  @moduledoc """
  Extracts function definitions and call edges from a single file using
  the same in-process parsers as the chunkers (`:epp` for Erlang,
  `Code.string_to_quoted` for Elixir) — not a second tree-sitter pass,
  which is what the original `call_extractor.py` uses. This is Phase 0's
  core untested hypothesis for the call graph: that a compiler-accurate
  parse can drive it too, and — for Erlang specifically — one that sees
  through macro expansion in a way tree-sitter structurally cannot, since
  `:epp` fully expands macros as part of parsing while tree-sitter only
  ever sees the raw `?MACRO(...)` token.

  Elixir macros are a different story: `Code.string_to_quoted/2` parses
  syntax only, it does not expand macros (that happens later, during
  compilation) — so a call hidden behind an Elixir macro is just as
  invisible here as it is to tree-sitter. The macro-transparency
  advantage is Erlang-specific.

  Returns `{defs, edges}`:
    * `defs`: `[%{name:, module:, file_path:, start_line:, end_line:}]`
    * `edges`: `[%{caller_module:, caller_name:, callee_module:, callee_name:, file_path:, line:}]`

  `callee_module: "?"` marks a call whose target module couldn't be
  statically resolved (e.g. `Mod:Fun()` where `Mod` is a variable, or
  `Mod.fun()` where `Mod` isn't a literal alias) — matching
  `call_extractor.py`'s convention so results stay comparable.
  """

  alias Beamscope.ErlangForms

  @spec extract_from_file(String.t(), keyword()) :: {[map()], [map()]}
  def extract_from_file(path, opts \\ []) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in [".erl", ".hrl"] -> extract_erlang(path, opts)
      ext when ext in [".ex", ".exs"] -> extract_elixir(path)
      _ -> {[], []}
    end
  end

  # --- Erlang ---

  defp extract_erlang(path, opts) do
    include_dirs = Keyword.get(opts, :include_dirs, [])

    case ErlangForms.parse_owned_forms(path, include_dirs) do
      {:ok, forms, _partial?} ->
        module = erlang_module_name(forms)
        Enum.reduce(forms, {[], []}, &accumulate_erlang_form(&1, module, path, &2))

      {:error, _reason} ->
        {[], []}
    end
  end

  defp accumulate_erlang_form(
         {:function, line, name, _arity, clauses} = form,
         module,
         path,
         {defs, edges}
       ) do
    def_entry = %{
      name: to_string(name),
      module: module,
      file_path: path,
      start_line: line,
      end_line: max(line, ErlangForms.deep_max_line(form))
    }

    new_edges =
      clauses
      |> find_erlang_calls(module, [])
      |> Enum.map(&erlang_edge(&1, module, name, path))

    {[def_entry | defs], new_edges ++ edges}
  end

  defp accumulate_erlang_form(_other, _module, _path, acc), do: acc

  defp erlang_edge({callee_module, callee_name, call_line}, module, name, path) do
    %{
      caller_module: module,
      caller_name: to_string(name),
      callee_module: callee_module,
      callee_name: to_string(callee_name),
      file_path: path,
      line: call_line
    }
  end

  defp erlang_module_name(forms) do
    Enum.find_value(forms, "", fn
      {:attribute, _line, :module, name} -> to_string(name)
      _ -> nil
    end)
  end

  defp find_erlang_calls(tuple, module, acc) when is_tuple(tuple) do
    acc = accumulate_call(tuple, module, acc)
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &find_erlang_calls(&1, module, &2))
  end

  defp find_erlang_calls(list, module, acc) when is_list(list),
    do: Enum.reduce(list, acc, &find_erlang_calls(&1, module, &2))

  defp find_erlang_calls(_other, _module, acc), do: acc

  defp accumulate_call({:call, line, target, _args}, module, acc) do
    case resolve_erlang_target(target) do
      {callee_module, callee_name} ->
        callee_module = if callee_module == :local, do: module, else: callee_module
        [{callee_module, callee_name, line} | acc]

      nil ->
        acc
    end
  end

  defp accumulate_call(_other, _module, acc), do: acc

  # Local call: foo(Args).
  defp resolve_erlang_target({:atom, _, fn_name}), do: {:local, fn_name}
  # Remote call, literal module: mod:foo(Args).
  defp resolve_erlang_target({:remote, _, {:atom, _, mod}, {:atom, _, fn_name}}),
    do: {to_string(mod), fn_name}

  # Remote call, dynamic module: Mod:foo(Args) where Mod is a variable/expression.
  defp resolve_erlang_target({:remote, _, _dynamic_mod, {:atom, _, fn_name}}), do: {"?", fn_name}
  # Fully dynamic (function name itself isn't a literal atom) — can't resolve at all.
  defp resolve_erlang_target(_other), do: nil

  # --- Elixir ---

  # Kernel.SpecialForms macros plus common operators — Elixir's AST has no
  # structural tag distinguishing a real function call from `case`, `+`,
  # a struct literal, etc. (everything is `{atom, meta, args}`), unlike
  # tree-sitter's Elixir grammar, which tags `call` nodes explicitly. This
  # exclusion list is how we approximate that same distinction.
  @elixir_non_calls MapSet.new(
                      (Kernel.SpecialForms.__info__(:macros) |> Enum.map(&elem(&1, 0))) ++
                        ~w(+ - * / == != === !== < > <= >= && || ! and or not in .. <> |> when -> <- \\\\)a
                    )

  defp extract_elixir(path) do
    source = File.read!(path)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast
        |> top_level_forms()
        |> Enum.reduce({[], []}, &walk_elixir(&1, path, [], &2))

      {:error, _reason} ->
        {[], []}
    end
  end

  defp top_level_forms({:__block__, _meta, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp walk_elixir(
         {:defmodule, _meta, [{:__aliases__, _, mod_parts}, module_opts]},
         path,
         module_path,
         acc
       ) do
    new_path = module_path ++ mod_parts

    module_opts
    |> Keyword.get(:do)
    |> top_level_forms()
    |> Enum.reduce(acc, &walk_elixir(&1, path, new_path, &2))
  end

  defp walk_elixir({def_kind, meta, [head | rest]}, path, module_path, {defs, edges})
       when def_kind in [:def, :defp, :defmacro, :defmacrop] do
    name = elixir_function_name(head)
    module = Enum.join(module_path, ".")
    start_line = meta[:line]
    end_line = max(start_line, elixir_max_line({head, rest}))

    def_entry = %{
      name: to_string(name),
      module: module,
      file_path: path,
      start_line: start_line,
      end_line: end_line
    }

    new_edges =
      rest
      |> find_elixir_calls(module, [])
      |> Enum.map(fn {callee_module, callee_name, call_line} ->
        %{
          caller_module: module,
          caller_name: to_string(name),
          callee_module: callee_module,
          callee_name: to_string(callee_name),
          file_path: path,
          line: call_line
        }
      end)

    {[def_entry | defs], new_edges ++ edges}
  end

  defp walk_elixir(_other, _path, _module_path, acc), do: acc

  defp elixir_function_name({:when, _meta, [inner_head, _guard]}),
    do: elixir_function_name(inner_head)

  defp elixir_function_name({name, _meta, _args}) when is_atom(name), do: name

  # Macro-generated name (e.g. `def unquote(name)(...)`) — can't be
  # statically resolved to an atom, same "?" convention as an unresolved
  # dynamic-module Erlang call below.
  defp elixir_function_name(_other), do: :"?"

  # Remote call: Mod.fun(args).
  defp find_elixir_calls(
         {{:., meta, [{:__aliases__, _, mod_parts}, fn_name]}, _meta2, args} = node,
         module,
         acc
       )
       when is_list(args) and is_atom(fn_name) do
    callee_module = Enum.join(mod_parts, ".")
    acc = [{callee_module, fn_name, meta[:line]} | acc]
    recurse_into_elixir_children(node, module, acc)
  end

  # Remote call, dynamic module: mod.fun(args) where mod isn't a literal alias.
  defp find_elixir_calls({{:., meta, [_dynamic_mod, fn_name]}, _meta2, args} = node, module, acc)
       when is_list(args) and is_atom(fn_name) do
    acc = [{"?", fn_name, meta[:line]} | acc]
    recurse_into_elixir_children(node, module, acc)
  end

  # Local call: fun(args) — excluding special forms/operators, which share
  # the same {atom, meta, args} shape but aren't real function calls.
  defp find_elixir_calls({name, meta, args} = node, module, acc)
       when is_atom(name) and is_list(args) do
    acc =
      if MapSet.member?(@elixir_non_calls, name) do
        acc
      else
        [{module, name, meta[:line]} | acc]
      end

    recurse_into_elixir_children(node, module, acc)
  end

  defp find_elixir_calls(tuple, module, acc) when is_tuple(tuple),
    do: recurse_into_elixir_children(tuple, module, acc)

  defp find_elixir_calls(list, module, acc) when is_list(list),
    do: Enum.reduce(list, acc, &find_elixir_calls(&1, module, &2))

  defp find_elixir_calls(_other, _module, acc), do: acc

  defp recurse_into_elixir_children(tuple, module, acc) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &find_elixir_calls(&1, module, &2))
  end

  defp elixir_max_line(ast) do
    {_ast, max_seen} =
      Macro.prewalk(ast, 0, fn
        {_, meta, _} = node, acc when is_list(meta) ->
          {node, max(acc, Keyword.get(meta, :line, 0))}

        node, acc ->
          {node, acc}
      end)

    max_seen
  end
end
