defmodule Beamlens.ErlangForms do
  @moduledoc """
  Shared `:epp` parsing used by both `ErlangChunker` and the call-graph
  extractor: parses a file in-process and filters out forms that
  originated in an `-include`'d header rather than the file itself.

  `:epp` inlines the forms of every included file directly into the form
  list, marking file boundaries with `{:attribute, _, :file, {Filename, _}}`
  pseudo-forms. Each source file is processed independently elsewhere in
  the pipeline, so forms belonging to an included header are dropped here
  — otherwise a shared header's content would be duplicated (and have its
  *text*/line-numbers misattributed) under every file that includes it.
  """

  @type parse_result :: {:ok, [tuple()], partial? :: boolean()} | {:error, term()}

  @spec parse_owned_forms(String.t(), [String.t()]) :: parse_result()
  def parse_owned_forms(path, include_dirs \\ []) do
    epp_opts = [includes: Enum.map(include_dirs, &to_charlist/1)]

    case :epp.parse_file(to_charlist(path), epp_opts) do
      {:ok, forms} ->
        {own_forms, partial?} = forms_owned_by_file(forms, path)
        {:ok, own_forms, partial?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # erl_parse forms are (almost) uniformly shaped `{tag, Line, ...}`, all the
  # way down into subexpressions (`{atom, Line, foo}`, `{var, Line, 'X'}`,
  # etc). Walking the whole form and taking the max integer that appears in
  # the "line" position gives an accurate end-of-span line without needing a
  # second, form-specific traversal for every node type erl_parse defines.
  @spec deep_max_line(term(), non_neg_integer()) :: non_neg_integer()
  def deep_max_line(term, acc \\ 0)

  def deep_max_line(tuple, acc) when is_tuple(tuple) do
    acc =
      case tuple do
        {tag, line, _} when is_atom(tag) and is_integer(line) -> max(acc, line)
        {tag, line, _, _} when is_atom(tag) and is_integer(line) -> max(acc, line)
        {tag, line} when is_atom(tag) and is_integer(line) -> max(acc, line)
        _ -> acc
      end

    tuple |> Tuple.to_list() |> Enum.reduce(acc, &deep_max_line/2)
  end

  def deep_max_line(list, acc) when is_list(list), do: Enum.reduce(list, acc, &deep_max_line/2)
  def deep_max_line(_other, acc), do: acc

  defp forms_owned_by_file(forms, path) do
    {reversed, _current_file, partial?} =
      Enum.reduce(forms, {[], nil, false}, fn
        {:attribute, _line, :file, {filename, _}}, {acc, _current, partial?} ->
          {acc, to_string(filename), partial?}

        {:error, _reason}, {acc, current, _partial?} ->
          {acc, current, true}

        {:eof, _line}, acc_state ->
          acc_state

        form, {acc, current, partial?} ->
          if current == path do
            {[form | acc], current, partial?}
          else
            {acc, current, partial?}
          end
      end)

    {Enum.reverse(reversed), partial?}
  end
end
