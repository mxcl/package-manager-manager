![Package Middle Manager screenshot](docs/pmm-promo.png)

# Package (Middle) Manager

A macOS app for seeing the packages you installed with all the other package managers.

> [!WARNING]
> Requires macOS 26. This is a SwiftUI/Liquid Glass app, not a portable dashboard. Yet.

## Quickstart

```sh
$ scripts/build.sh --run
Built /Users/you/src/pmm/dist/Package Middle Manager.app
# ^^ builds the app, signs it ad-hoc, then opens it
```

Install it into `/Applications`:

```sh
$ scripts/build.sh --install --run
Built /Applications/Package Middle Manager.app
```

The app bundles a menu bar helper. The helper does the slow work in the
background, writes a snapshot to Application Support, and the main window reads
that. The UI should stay usable while your package managers do package manager
things.

## What It Finds

P(m)M currently inventories:

- Homebrew formulae and casks
- global npm packages
- npx cache entries
- `uv tool` tools and `uv` Python installs
- `uvx` cached environments
- `cargo install` binaries
- `rustup` and installed Rust toolchains

It also pulls package summaries, categories, URLs, and latest-version metadata
where the project has a source for it. If metadata is missing, the package still
shows up. It just looks less informed. Fair.

## Updating and Removing

The detail pane offers update and uninstall actions when P(m)M knows the native
command to run.

Supported update paths:

- `brew upgrade`
- `npm install --global package@latest`
- `npm exec --yes --package package@version -- true`
- `uv tool upgrade`
- `uv python install`
- `cargo install --force`

Supported uninstall paths:

- `brew uninstall`
- `npm uninstall --global`
- remove npx cache entries
- `uv tool uninstall`
- `uv python uninstall`
- remove uvx cached environments
- `cargo uninstall`

> [!IMPORTANT]
> `rustup` is inventory-only for now. P(m)M will show `rustup` and toolchains,
> but it will not update or uninstall them.

## CLI

There is a small CLI for the same inventory scan:

```sh
$ swift run pmmctl --help
Usage: pmmctl [--json] [--outdated]
```

Use `--json` when you want the app's package model instead of tab-separated
rows.

## Development

```sh
$ swift test

$ scripts/build.sh --run
```

The package exports three products:

- `PMMApp`, the main window
- `PMMMenuBar`, the helper/menu bar app
- `pmmctl`, the CLI

## Caveats

P(m)M shells out to your package managers. It does not replace them, normalize
their data perfectly, or pretend their caches are a coherent database.

Homebrew metadata requires `brew update` in the helper refresh path. Network
metadata is best-effort; local inventory should still work when that data is
unavailable.

For everything else:

```sh
$ scripts/build.sh --help
$ swift run pmmctl --help
```
