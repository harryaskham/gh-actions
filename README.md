# gh-actions

Shared, non-secret GitHub Actions definitions for harryaskham repositories.
Reusable workflows live in `.github/workflows/` and are called from other
repositories with `uses: harryaskham/gh-actions/.github/workflows/<file>@main`.

Secrets never live here. Callers pass their own repository secrets.

## FlakeHub

[FlakeHub](https://flakehub.com) hosts flake releases, an access-controlled
binary cache (FlakeHub Cache), and pre-resolved store paths for `fh resolve` /
`fh apply`. Only CI identities can write to it (GitHub Actions OIDC, so
`id-token: write` is mandatory). Machines read with a FlakeHub token; in
Collective that is `keys/flakehub/personal`, wired by
`modules/agnostic/flakehub.nix`.

Paths pushed by a repository's CI belong to that repository's FlakeHub flake.
Anyone who can read the flake can substitute them. Private flakes and the
cache need the paid plan (active for `harryaskham`).

### Recipe 1: everything, GitHub-hosted (small projects)

`.github/workflows/flakehub.yml` in the project:

```yaml
name: FlakeHub
on:
  push:
    branches: [main]
    tags: ["v?[0-9]+.[0-9]+.[0-9]+*"]
  pull_request:
  workflow_dispatch:
jobs:
  flakehub:
    uses: harryaskham/gh-actions/.github/workflows/flakehub-ci.yml@main
    permissions:
      id-token: write
      contents: read
    with:
      visibility: private   # or public / unlisted; omit to cache only
```

This discovers every derivation output for x86_64-linux, aarch64-linux and
aarch64-darwin, builds them, pushes them to FlakeHub Cache, and publishes a
rolling release (`0.1.<commit count>`) from `main`, or a semver release from a
tag. Private repos pay GitHub-hosted minutes (macOS minutes count 10x).

### Recipe 2: explicit targets and/or self-hosted runners

```yaml
jobs:
  flakehub:
    uses: harryaskham/gh-actions/.github/workflows/flakehub-build.yml@main
    permissions:
      id-token: write
      contents: read
    with:
      builds: >-
        [
          {"name": "x86_64-linux", "runner": "ubuntu-latest",
           "installable": ".#packages.x86_64-linux.default"},
          {"name": "aarch64-darwin", "runner": "macos-latest",
           "installable": ".#packages.aarch64-darwin.default"}
        ]
      visibility: private
```

| Input | Default | Notes |
| --- | --- | --- |
| `builds` | required | JSON list of `{name, runner, installable}`; `runner` may be a label list for self-hosted runners. |
| `install-nix` | `true` | Set `false` on self-hosted hosts that already run Nix. |
| `isolate-home` | `false` | Per-job HOME; set on long-lived self-hosted runners so the cache action's nix.conf edits don't accumulate. Daemon ports are always derived per runner. |
| `enqueue-closures` | `true` | Pushes each full closure explicitly. Long-lived runners never rebuild paths already in their store, so the post-build hook alone misses them. |
| `visibility` | empty | `public`, `unlisted` or `private` publishes after all builds pass. Empty only populates the cache. |
| `include-output-paths` | `true` | Publishes resolved store paths for `fh resolve` / `fh apply`. |
| `enable-ssh-agent` + secret `ssh-private-key` | off | Private `git+ssh` inputs. |
| secret `github-token` | none | Private `github:` inputs (`access-tokens`). |
| `publish-runner` | `"ubuntu-latest"` | JSON `runs-on` for the publish job. |

### Consuming

- Inputs: `inputs.foo.url = "https://flakehub.com/f/harryaskham/foo/*";`
  (private flakes authenticate through the netrc Collective installs).
- Binaries: any machine with the FlakeHub token substitutes automatically.
- Deploy without evaluating: `fh resolve "harryaskham/foo/*#packages.x86_64-linux.default"`.

## Self-test

`self-test.yml` runs `flakehub-build.yml` on x86_64-linux and aarch64-linux
against `test/selftest`, two `/bin/sh` derivations whose paths change every
commit. A fresh runner then substitutes the closure with `--max-jobs 0`. It
never publishes.
