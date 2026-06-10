# Release Scripts

`build-macos-app.sh` builds the Release macOS app, verifies the signature and
hardened runtime, checks that the Rust core is statically linked, confirms the
document-type bundle metadata, and writes a zip archive under
`target/release-artifacts/`.

Local ad-hoc build:

```sh
scripts/release/build-macos-app.sh
```

Developer ID build:

```sh
LOCUS_CODE_SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
LOCUS_DEVELOPMENT_TEAM="TEAMID" \
scripts/release/build-macos-app.sh
```

Notarization is intentionally not automated until the project has stable
Apple Developer credentials in its release environment.
