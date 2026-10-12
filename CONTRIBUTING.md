# Contributing to Eyelid

Thanks for helping. Issues and pull requests are welcome. For anything bigger than a small fix, please open an issue first so we can agree on the approach.

By taking part, you agree to follow the [code of conduct](CODE_OF_CONDUCT.md). Security problems go through [private reporting](SECURITY.md), not public issues.

## Reporting a bug or asking for a feature

Use the issue forms: they ask for what's usually needed, such as the Eyelid and macOS versions and the Mac's model. For a bug, steps that reproduce it help the most, along with a screenshot or a screen recording of the notch when it's about how it looks.

## Building and testing

[Build from source](README.md#build-from-source) in the README covers what you need and the `make` commands. `make test` runs the unit tests.

- **Tests** cover what can be checked without a screen: decoding the adapter's output and early titles, playback time and seeking, the artwork wait and color, the track title's layout and timing, the equalizer's bands, battery events, media keys and level steps, volume set elsewhere, device icons, the notch's layout, sections, outline and hover areas, the shelf and drops, the clipboard history and its keys, app volumes and their taps, each app's equalizer, the translator and double copies, shortcuts, settings, and artwork limits.
- **On a real Mac:** hovering, haptics, animations and the look of the notch still need a try. Mention what you checked in your pull request.

## Making a change

- **Branches:** `main` is the latest release, and `develop` collects work for the next one. It's the default branch, so branch off it, for example `feat/calendar`, and open your pull request against it.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `ci:` and so on.
- **CI** builds and tests every pull request and every push to `main` and `develop` on macOS 26. The built app is attached to each run as a zip for 14 days, so you can try a change without building it yourself.
- **Pull requests** say what changed and why, and how it was tested. The template asks for both.
- **Code and docs** are in English. Comments explain why, not what.

## Releasing (maintainers)

1. Open a pull request to `main` titled `Release X.Y.Z`, from `develop` or from a `release/X.Y.Z` branch off `develop` for last changes such as the release notes. Merge it with a merge commit once the checks pass.
2. Tag the merge commit on `main`:

   ```sh
   git switch main && git pull
   git tag -a v0.2.0 -m "Eyelid 0.2.0"
   git push origin v0.2.0
   ```

3. Bring the release back into `develop`, so development builds pick up the new version:

   ```sh
   git switch develop && git pull
   git merge main
   git push
   ```

4. The [Homebrew tap](https://github.com/Satis-ku/homebrew-tap) picks up the release within a day. To update it right away:

   ```sh
   gh workflow run update.yml --repo Satis-ku/homebrew-tap
   ```

The Release workflow runs the tests and builds a universal app stamped with the tag's version. It checks the version, the architectures, the minimum macOS version, the signature and the protections listed under [Security](README.md#security). This build job can only read the repository. A separate publish job, the only one that can write, signs a build provenance attestation for the zip, then publishes a GitHub release with the zip, its SHA-256 checksum, and notes generated from the merged pull requests. Tags with a suffix, such as `v0.2.0-beta.1`, become prereleases.
