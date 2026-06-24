# macOS Scripts

Build, signing, notarization, and local packaging scripts for the macOS app.

## Run App

From the repository root:

```sh
scripts/mac/run-app.sh
```

Use Release when you want to check the optimized app bundle:

```sh
scripts/mac/run-app.sh --release
```

## Install App

Use this when Locus is ready for daily use from Applications rather than from
the repository build folder:

```sh
scripts/mac/install-app.sh
```

The script builds a Release app with derived data and release artifacts outside
the repository by default, then installs:

```text
/Applications/Locus.app
```

The same flow is available from the repository root:

```sh
make install
```

Useful overrides:

```sh
scripts/mac/install-app.sh --destination "$HOME/Applications/Locus Beta.app"
scripts/mac/install-app.sh --user
scripts/mac/install-app.sh --no-open
```
