# Fixtures

Sample documents and workspaces for development and tests live here.

Do not place private or sensitive user files in this directory.

All fixture content should be synthetic, small, and stable. Prefer adding a
focused fixture that captures one behavior over copying real user documents.

## Layout

- `workspaces/`: directory trees for listing, sorting, ignored-file, symlink,
  and file type tests.
- `markdown/`: Markdown documents for editor, search, diff, and preview tests.
- `config/`: JSON, YAML, and TOML samples for structured text handling.
- `plain/`: CSV, TSV, text, and log samples.
- `media/`: tiny valid text-based media and intentionally invalid media files.
- `pdf/`: small PDF samples and invalid PDF boundary cases.
- `office/`: Office handoff and error-handling samples.

Intentionally invalid files must live under an `invalid/` directory or include
`invalid` in the file name so tests do not mistake them for preview-ready
documents.
