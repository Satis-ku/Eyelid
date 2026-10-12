## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask satis-ku/tap/eyelid
```

Or by hand: download the `Eyelid-*.zip` below, unzip it, and move `Eyelid.app` to your Applications folder.

Eyelid isn't notarized, so macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Eyelid.app
```

If you use the volume and brightness HUD, remove Eyelid from **System Settings → Privacy & Security → Accessibility** after updating, and allow it again. Eyelid is signed ad hoc, so macOS sees each version as a new app: it may also ask again to let Eyelid record system audio (for the equalizer and apps' own volumes) and paste from other apps (for the clipboard history and translating what you copy).

Built for macOS 14 or later, on Apple silicon or Intel. Each app's volume and equalizer need macOS 14.2, and the translator needs macOS 26. The `.sha256` file holds the zip's SHA-256 checksum.
