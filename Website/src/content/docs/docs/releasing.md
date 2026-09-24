---
title: Releasing
description: How a signed, notarised release is made from GitHub Actions, the one-time setup it needs, and trying the pipeline by hand.
---

Releases come from `.github/workflows/release.yml`, from `main` only: push a tag on a commit on
`main`, or run the *Release* workflow by hand, which tags the current `main`.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

```bash
gh workflow run release.yml -f version=0.2.0
```

It tests, builds with the version from the tag and the commit count as the build number, signs with
the Developer ID, notarises and staples the disk image, writes a signed `appcast.xml`, and publishes
both on a GitHub release.

Installed copies read `releases/latest/download/appcast.xml`, which GitHub redirects to the appcast
on the newest release. Publishing the release *is* publishing the update.

## The changelog is the release notes

What a release says is `CHANGELOG.md`'s section for its version. It becomes the GitHub release's
description and the notes Caliper shows in its update window, so it is written for someone deciding
whether to install. **A version with no section is refused before anything is built** — to release,
rename `[Unreleased]` to the version and date it.

## One-time setup

1. **The update key.** `make update-key` makes the EdDSA key pair Sparkle checks every update against,
   keeps the private half in your login Keychain (account `caliper`), and writes the public half into
   `Resources/Info.plist`. Keep a copy of the private key somewhere safe: installed copies can only be
   moved off a lost key by a release signed with the same Developer ID.
2. **A `release` environment.** *Settings ▸ Environments ▸ New environment*, named `release`. Under
   *Deployment branches and tags*, choose *Selected branches and tags* and add the branch `main` and
   the tag pattern `v*`, so its secrets are out of reach of every other branch and tag.
3. **Its secrets**, each set with `gh secret set <NAME> --env release`:

   | Secret | What it holds |
   |---|---|
   | `DEVELOPER_ID_CERTIFICATE` | The *Developer ID Application* certificate with its private key, exported from Keychain Access as a `.p12` and base64-encoded: `base64 -i developer-id.p12 \| gh secret set DEVELOPER_ID_CERTIFICATE --env release` |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password the `.p12` was exported with |
   | `NOTARY_API_KEY` | An App Store Connect API key, the whole `AuthKey_….p8` file, made under *Users and Access ▸ Integrations ▸ App Store Connect API* with the Developer role |
   | `NOTARY_API_KEY_ID` | That key's ID |
   | `NOTARY_API_ISSUER_ID` | The issuer ID shown above the list of keys |
   | `SPARKLE_PRIVATE_KEY` | The update key, exported as `make update-key` shows at the end |

Secrets stay private when the repository is public: GitHub never shows one again once it is set, and
workflows run for pull requests from forks get none at all.

## Signing, piece by piece

Notarisation checks every piece of code in the bundle, not only the app, so Sparkle's helpers are
signed one by one, innermost first, by `Tools/sign.sh` — each with the hardened runtime and a secure
timestamp. A signature without a timestamp stops verifying the day the certificate expires.

## By hand

To try the pipeline on your own Mac, with a notary profile stored once by
`xcrun notarytool store-credentials`:

```bash
NOTARY_PROFILE=CaliperNotary make package
```

```bash
CALIPER_VERSION=0.2.0 CALIPER_BUILD=212 NOTARY_PROFILE=CaliperNotary make package
```

The first makes a development build, which never updates itself; the second a release build. Without
`NOTARY_PROFILE` it stops after signing and says so. The disk image lands in `build/`.
