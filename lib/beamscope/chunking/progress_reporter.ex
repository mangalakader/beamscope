defmodule Beamscope.Chunking.ProgressReporter do
  @moduledoc """
  Optional `:telemetry` handler that prints a live-updating progress line
  and a polished summary while `Pipeline.chunk_repo/2` runs.

  Not attached automatically — `Pipeline` stays free of IO by default so
  it's safe to call from tests or as a library. Attach explicitly around a
  `chunk_repo/2` call:

      Beamscope.Chunking.ProgressReporter.attach()
      Pipeline.chunk_repo(repo_path)
      Beamscope.Chunking.ProgressReporter.detach()

  In an interactive terminal (`IO.ANSI.enabled?/0`), progress overwrites a
  single line via `\\r`. Piped/redirected output (CI logs, `| tee`, etc.)
  isn't a real TTY, so `\\r` would just dump onto one unreadable line
  instead — there, it prints roughly 20 discrete progress lines across the
  run instead.
  """

  @handler_id "beamscope-spike-progress-reporter"
  @events [
    [:beamscope, :chunk_repo, :start],
    [:beamscope, :chunk_repo, :file, :stop],
    [:beamscope, :chunk_repo, :stop]
  ]

  # :counters slots — kept here rather than in the (immutable, passed-by-
  # value) handler config so they can be updated across calls for the
  # lifetime of one attachment.
  @completed_slot 1
  @start_time_slot 2
  @file_count_slot 3

  @spec attach() :: :ok
  def attach do
    counters = :counters.new(3, [])

    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{
      counters: counters
    })
  end

  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, measurements, metadata, config)

  def handle_event(
        [:beamscope, :chunk_repo, :start],
        measurements,
        metadata,
        %{counters: counters}
      ) do
    :counters.put(counters, @completed_slot, 0)
    :counters.put(counters, @start_time_slot, System.monotonic_time())
    :counters.put(counters, @file_count_slot, measurements.file_count)
    IO.puts("Chunking #{measurements.file_count} files under #{metadata.repo_path} ...")
  end

  def handle_event(
        [:beamscope, :chunk_repo, :file, :stop],
        measurements,
        metadata,
        %{counters: counters}
      ) do
    :counters.add(counters, @completed_slot, 1)
    completed = :counters.get(counters, @completed_slot)
    file_count = :counters.get(counters, @file_count_slot)
    rate = rate_per_sec(completed, elapsed_ms(counters))

    line =
      "#{completed}/#{file_count} files chunked (#{rate}/s) — last: #{Path.basename(metadata.file_path)} " <>
        "(#{metadata.chunk_count} chunks, #{format_ms(measurements.duration)})"

    if IO.ANSI.enabled?() do
      IO.write("\r  " <> line <> String.duplicate(" ", 10))
    else
      step = max(div(file_count, 20), 1)
      if rem(completed, step) == 0 or completed == file_count, do: IO.puts("  " <> line)
    end
  end

  def handle_event([:beamscope, :chunk_repo, :stop], measurements, metadata, _config) do
    if IO.ANSI.enabled?(), do: IO.puts("")

    IO.puts("""
    Done chunking #{metadata.repo_path}
      total chunks: #{measurements.total_chunks}
      errors:       #{measurements.total_errors}
      elapsed:      #{format_duration(measurements.duration)}
    """)
  end

  defp elapsed_ms(counters) do
    start_time = :counters.get(counters, @start_time_slot)
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end

  defp rate_per_sec(_completed, 0), do: 0
  defp rate_per_sec(completed, elapsed_ms), do: round(completed * 1000 / elapsed_ms)

  defp format_ms(native), do: "#{System.convert_time_unit(native, :native, :millisecond)}ms"

  defp format_duration(native) do
    ms = System.convert_time_unit(native, :native, :millisecond)
    "#{Float.round(ms / 1000, 2)}s"
  end
end
