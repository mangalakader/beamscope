# :external tests hit real Bumblebee/Torchx model download+load (first run
# only, but still real network + CPU time) — excluded by default so
# `mix test` stays fast; run `mix test --include external` to include them.
ExUnit.start(exclude: [:external])
