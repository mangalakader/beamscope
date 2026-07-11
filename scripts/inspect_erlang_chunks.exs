alias Beamlens.Chunking.ErlangChunker

fixtures_dir = Path.join(File.cwd!(), "priv/fixtures")

fixtures_dir
|> File.ls!()
|> Enum.filter(&String.ends_with?(&1, ".erl"))
|> Enum.sort()
|> Enum.each(fn filename ->
  path = Path.join(fixtures_dir, filename)
  chunks = ErlangChunker.chunk_file(path, include_dirs: [fixtures_dir])

  IO.puts("== #{filename} (#{length(chunks)} chunks) ==")

  Enum.each(chunks, fn chunk ->
    warning = if chunk.warning, do: " [warn:#{chunk.warning}]", else: ""
    IO.puts("  #{chunk.kind} #{chunk.symbol} L#{chunk.start_line}-#{chunk.end_line}#{warning}")
  end)

  IO.puts("")
end)
