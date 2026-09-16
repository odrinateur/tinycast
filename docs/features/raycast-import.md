# Raycast import

Tinycast reads the `.rayconfig` files Raycast writes: the older `RAYCFG3` container and the
newer sealed file, which is AES-256-CBC from end to end with no plaintext header. Each has its
own path in `RaycastDecoder`; both unwrap to the same category-keyed payload JSON.

## Invariants

- **`RaycastDecoder` stays platform-UI-free** so `raycast-test` compiles it standalone. Which is why the
  decoder returns the payload's own bytes and `RaycastImportReader`, not the decoder, validates them
  against `PopToRootTimeout` / `HyperKeyPhysicalKey` / `KeyShortcut`.
-   **Recognition is the container signature and nothing else, where there is one.** `RaycastDecoder.isExport` needs no
    passphrase, so the Backup pane runs it the moment a file is chosen and a wrong passphrase reports a
    wrong passphrase instead of "not a Raycast export". The sealed file carries no signature, so block
    alignment past a random header is its only pre-passphrase signal.
- **Never commit a real `.rayconfig` as a fixture.** The harness builds its own.
- **Every scrypt derive costs seconds in the unoptimized harness.** `raycast-test` derives once for its
  fixture and keeps the cases that reach key derivation to the few that need it; anything testing the
  container's framing is written to fail before it.
- **The payload gunzip cap is a memory bound, not a zip-bomb guard.** AES-GCM has already authenticated
  those bytes. The unauthenticated header stays at 1 MB. A clipboard-heavy export decompresses past
  64 MB, so the payload cap is 512 MB.

## Wire format

The container:

```
file = "RAYCFG3\n" ‖ UInt32LE(header.count) ‖ gzip(header JSON) ‖ ciphertext ‖ tag(16)
body = AES-256-GCM(gzip(payload JSON))
key  = scrypt(passphrase, salt, N=16384, r=8, p=1, dkLen=32)
```

The header carries `schemaVersion`, `iv` and `salt`, hex-encoded, 16 bytes each. `schemaVersion` is
Raycast's own container number and is **3**; anything else is rejected.

The sealed file:

```
file = AES-256-CBC(16 random bytes ‖ gzip(payload JSON))
key  = SHA256(passphrase)
iv   = SHA256(key ‖ passphrase)[0..<16]
```

CBC carries no authentication tag, so a wrong passphrase and a corrupt file both fail the same
way and both report `incorrectPassphrase`. CryptoKit has no CBC, so this one path goes through
CommonCrypto instead.

The header carries `schemaVersion`, `iv` and `salt`, hex-encoded, 16 bytes each. `schemaVersion` is
Raycast's own container number and is **3**; anything else is rejected. The payload is category-keyed
JSON: `settings`, `clipboardHistory`,
and a `quicklinks` object holding `quicklinks` plus `openWithPlatforms`.

Raycast encrypts even when the user never chose a password — it generates one and stores it in the
login keychain (service `Raycast`, account `export_passphrase`), viewable at Raycast → Settings →
Extensions → Export Settings & Data. **Tinycast never reads the keychain**; the user supplies the
passphrase.

## Mapping

The container payload is category-keyed (`settings`, `clipboardHistory`, `quicklinks`); the sealed
payload is package-keyed (`builtin_package_*`). Each has its own mapper in `RaycastImportReader`,
and both land on the same `SettingsBackup`.

An applications command hides the launched app's path after `::=::` in its id, resolved through
`Bundle` to a bundle ID — the same resolution the hotkey, favorite and alias mappers all use. Hotkeys
are `LayoutIndependent` key codes with named modifiers, and always import as a `.combo`: Raycast has no
double-tap binding. The sealed payload names its global hotkey as one chord (`Command-49`), parsed
the same way, and its Hyper key arrives as a carbon key code matched against
`HyperKeyPhysicalKey`. A clipboard record's representations are nested and its timestamps carry fractional
seconds; only an `image/*` representation whose file still exists becomes an image clip, and the rest
are counted as missing rather than dropped silently. The sealed payload decides by `category` instead
(`text`, `link`, `color`, `image`, `file`): an image record's `text` is only its size label, so the
category is read first and the label never lands as a text clip. Quicklinks land through `QuicklinkArchive.merge`,
so they add to the library and never replace it. `{Query}` is rewritten to `{argument}`; an `openWith`
app path (or a platform id in `openWithPlatforms`) resolves to a bundle ID the same way application
hotkeys do. Raycast's ULID is discarded — each imported row gets a fresh UUID, as a JSON quicklink
import already does. Importing at least one quicklink turns `quicklinksEnabled` on: opening a link
grants no permission class. Disabled quicklinks stay out. The sealed payload carries no favorites,
aliases or per-command hotkeys, so those categories yield nothing from it.

Ranking seeds come from `rootSearch`: only `systemApp` entries meet a Tinycast preference key, and
each comma-separated `searchTerms` prefix becomes one learned row, counted by repetition — the same
rows a launch would have written. Quicklink frecency reconciles by rewritten link, since the import
mints fresh UUIDs; commands have no counterpart and stay out. They merge
(`LauncherRankingStore.mergeImported`) rather than
replace, so Tinycast's own habits survive and a re-import adds nothing. The sealed payload carries
no frequency, so every seed counts its repetitions with its last-opened date; real use overtakes
them the way any habit overtakes another.

Script commands are not in a `.rayconfig` — they are files in a folder Raycast points at — so they
have their own importer, described in
[custom-commands.md](custom-commands.md#importing-raycast-scripts).

## Layout

`RaycastDecoder` unwraps the container and returns Raycast's own values; `RaycastImportReader` turns
those into Tinycast's domain types. The reader needs AppKit, so it lives in `Service/` and is covered by
the app build rather than the harness.

`RaycastImport` is only the data: `Result`, `selecting(_:)` and `RaycastImportOptions`.
`BackupActions.importRaycast` runs the reader off the main actor.
