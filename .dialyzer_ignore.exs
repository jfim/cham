# Curated dialyzer false positives. Each entry is one of:
#   {"path/to/file.ex", "warning substring"}  |  {"path/to/file.ex"}  |  ~r/regex/
# Keep this empty unless a warning is a genuine false positive — fix real ones.
[
  # Ecto.Multi uses an opaque type internally; dialyzer raises call_without_opaque
  # when building a pipeline with Ecto.Multi.new() |> Ecto.Multi.insert(...).
  # This is a well-known Ecto/dialyzer false positive — the code is correct.
  # Scoped to the insert description (not file-wide :call_without_opaque) so it
  # can't mask an unrelated opaque-type bug elsewhere in this module.
  {"lib/cham/archive.ex", "Type mismatch in call without opaque term in insert."}
]
