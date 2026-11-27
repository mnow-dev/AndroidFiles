# Packaging

Manifests for desktop package managers (Windows Scoop/winget and macOS Homebrew Cask). Getting into these turns
"download an unsigned binary" into `winget install` /
`scoop install` / `brew install --cask`, and lists the app in their search indexes.

Update the version and hashes on every release. Hashes come from the release
assets — the zip and macOS DMG publish their own `.sha256`; compute the Windows installer's with
`Get-FileHash AndroidFiles-win-Setup.exe -Algorithm SHA256`.

## Scoop — `scoop/androidfiles.json` (ready)

Portable-zip based, so no installer quirks. To publish:
1. Add it to a bucket (your own repo, or submit to `ScoopInstaller/Extras`).
2. Users then run `scoop bucket add <bucket>` and `scoop install androidfiles`.

Verified: the zip has `android_files.exe` at its root, so `bin`/`shortcuts`
resolve correctly. `checkver`/`autoupdate` track new GitHub releases.

## winget — `winget/*.yaml` (draft — verify one thing first)

Multi-file manifest for `mnow-dev.AndroidFiles`. Before opening a PR to
`microsoft/winget-pkgs`:
1. **Verify the Velopack `Setup.exe` silent-install switch.** winget requires
   an unattended install. Confirm whether it's `--silent`, another flag, or
   whether Velopack already installs without UI (then drop `InstallerSwitches`
   and keep `InstallModes`). Test with
   `winget install --manifest packaging/winget` in a sandbox.
2. Validate: `winget validate packaging/winget`.
3. Fork `microsoft/winget-pkgs`, place the three files under
   `manifests/m/mnow-dev/AndroidFiles/0.2.0/`, and open a PR. Their CI installs
   it in a sandbox to confirm it works.

## Homebrew Cask — `homebrew/androidfiles.rb` (macOS)

macOS `.dmg` cask for a personal tap (`mnow-dev/homebrew-tap`) or `homebrew/homebrew-cask`.
To test locally:

```sh
brew install --cask packaging/homebrew/androidfiles.rb
```

Because the `.dmg` is not notarized yet, users install with `--no-quarantine` or allow it once in *System Settings → Privacy & Security → Open Anyway*.

## Chocolatey (not started)

Lower priority than winget/Scoop. A `.nuspec` + install script pointing at the
Setup.exe would do it; add here when needed.
