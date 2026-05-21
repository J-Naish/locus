# Performance Fixtures

Performance fixtures are generated, not committed.

Use:

```sh
scripts/generate-performance-fixtures.sh
```

By default this recreates `target/perf-fixtures/listing-1000` with a
deterministic non-recursive workspace for folder listing smoke tests.

Configuration:

- `LOCUS_PERF_FIXTURE_ROOT`: output root, defaults to `target/perf-fixtures`
- `LOCUS_PERF_ENTRY_COUNT`: number of generated top-level files, defaults to
  `1000`

The generated files are intentionally small. They measure listing, sorting,
classification, ignored-name filtering, path handling, and metadata overhead
without making the Git repository heavy.
