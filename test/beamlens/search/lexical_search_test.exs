defmodule Beamlens.Search.LexicalSearchTest do
  use ExUnit.Case, async: true

  alias Beamlens.Search.LexicalSearch

  describe "extract_terms/1 — exact-name queries (should extract something)" do
    test "snake_case identifier" do
      assert LexicalSearch.extract_terms("where is pop_messages defined for the offline backend") ==
               ["pop_messages"]
    end

    test "snake_case identifier, different phrasing" do
      assert "send_request_and_get_response" in LexicalSearch.extract_terms(
               "where is send_request_and_get_response defined"
             )
    end

    test "dotted qualified name expands to include the bare identifier" do
      terms = LexicalSearch.extract_terms("where is Calendar.ISO.date_to_string defined")

      assert "Calendar.ISO.date_to_string" in terms
      assert "date_to_string" in terms
    end

    test "qualified colon+arity form expands to the bare trailing identifier" do
      terms = LexicalSearch.extract_terms("what calls mongoose_backend:call_tracked/4")

      assert "mongoose_backend:call_tracked/4" in terms
      assert "call_tracked" in terms
    end

    test "backtick-quoted term is extracted even without snake_case/camelCase" do
      assert LexicalSearch.extract_terms("where is `authenticate` defined") == ["authenticate"]
    end

    test "double-quoted term is extracted" do
      assert LexicalSearch.extract_terms("find \"authenticate\"") == ["authenticate"]
    end
  end

  describe "extract_terms/1 — conceptual queries (should extract nothing)" do
    test "no exact name given" do
      assert LexicalSearch.extract_terms(
               "code that removes expired offline messages too old to deliver"
             ) == []
    end

    test "all-caps acronym doesn't false-positive as camelCase" do
      assert LexicalSearch.extract_terms(
               "code that connects an XMPP user and creates a dynamic domain"
             ) == []
    end

    test "a bare, unquoted single word is NOT extracted (documented gap — use backticks)" do
      assert LexicalSearch.extract_terms("where is authenticate defined") == []
    end
  end

  describe "extract_terms/1 — edge cases" do
    test "empty query" do
      assert LexicalSearch.extract_terms("") == []
    end

    test "whitespace-only query" do
      assert LexicalSearch.extract_terms("   ") == []
    end

    test "punctuation-only query" do
      assert LexicalSearch.extract_terms("???!!!") == []
    end

    test "camelCase identifier" do
      assert LexicalSearch.extract_terms("where is getUserSession defined") == ["getUserSession"]
    end
  end

  describe "search/3" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "beamlens_lexical_search_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "sample.ex"), """
      defmodule Sample do
        def pop_messages(host, jid) do
          :ok
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, dir: dir}
    end

    test "finds a real exact match with correct file_path/line", %{dir: dir} do
      assert [%{file_path: file_path, line: line, text: text}] =
               LexicalSearch.search(dir, "where is pop_messages defined")

      assert file_path == Path.join(dir, "sample.ex")
      assert line == 2
      assert text =~ "pop_messages"
    end

    test "returns [] for a conceptual query with no identifier-like terms", %{dir: dir} do
      assert LexicalSearch.search(dir, "code that pops messages off a queue") == []
    end

    test "returns every match, unbounded — capping happens in Beamlens.Repo after ranking, not here",
         %{dir: dir} do
      File.write!(Path.join(dir, "sample2.ex"), """
      defmodule Sample2 do
        def pop_messages(a), do: a
        def pop_messages(a, b), do: {a, b}
      end
      """)

      assert length(LexicalSearch.search(dir, "pop_messages")) == 3
    end

    test "returns [] rather than crashing for a nonexistent repo_path" do
      assert LexicalSearch.search("/tmp/beamlens_definitely_does_not_exist", "pop_messages") == []
    end
  end
end
