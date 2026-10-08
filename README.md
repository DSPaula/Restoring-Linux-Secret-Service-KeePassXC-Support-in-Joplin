# Restoring Linux Secret Service / KeePassXC Support in Joplin

A reproducible patch that restores Joplin's existing `node-keytar` → Secret Service
path on Linux, so the master password is stored in **KeePassXC** (via
`org.freedesktop.secrets`) instead of KWallet.

**Tested on:** Joplin 3.7.21 (AUR `joplin-desktop 3.7.21-1`) · Electron 34.5.8 ·
Arch Linux · KeePassXC. Byte-exact patch — expect to re-validate on other versions.

## Overview

The following conceptual map summarizes the problem, root cause, patch, resulting keychain chain, validation, and upstream direction. It is intentionally a **conceptual architecture map**, not a runtime trace.

mermaid
mindmap
  root((Joplin → KeePassXC))
    Problem
      KDE Linux uses Electron safeStorage
      backend: KWallet6
      log: "Keychain Service Linux backend: kwallet6"
      log: "Driver unsupported:node-keytar"
      KWallet contains "Chromium Safe Storage"
      bundled keytar already exists
    Root cause (v3.7.21)
      shim-init-node.ts
        Linux returns null for shim.keytar()
        node-keytar driver reports unsupported
      BaseApplication.ts
        Electron driver registered first
        safeStorage wins when available
      SettingUtils.ts
        Linux keychain forced read-only without feature flag
      Electron driver
        encrypted blob stays in Joplin KvStore
        OSCrypt key is stored in system keychain
    Solution: 3 byte-patches
      main.bundle.js + main-html.bundle.js
        1) .keytar:null → .keytar:require('keytar')
        2) disable canUseSafeStorage selection
        3) featureFlag.linuxKeychain !1 → !0
      resulting chain
        Joplin
          KeychainService
            node-keytar
              libsecret / D-Bus
                org.freedesktop.secrets
                  KeePassXC
      patch-joplin-keytar.sh
        extract
        exact-match validation
        node --check
        repack
    Validation
      electron-safeStorage becomes unsupported
      keytar set/get test returns mytest
      no new KWallet entries
      KeePassXC receives the keychain entry
    Install and rollback
      backup original app.asar
      replace with patched app.asar
      re-apply after package updates
    Testing gotcha
      custom ASAR test needs build/
      custom ASAR test needs app.asar.unpacked/
    Alternative (no patch)
      --password-store=gnome-libsecret after app path
      encrypted password remains in Joplin KvStore
    Upstream
      wire shim.keytar on Linux
      whitelist --password-store=
      revisit Linux read-only default

## Problem

On Linux, Joplin stores the master password via Electron `safeStorage`, whose backend
on KDE is KWallet. Log output:

    KeychainServiceDriver.electron: Keychain Service Linux backend: kwallet6
    KeychainService: Driver unsupported:node-keytar

The password material ends up in KWallet (`kwalletd6`, entries like "Chromium Safe
Storage") instead of KeePassXC — even though Joplin **already ships** the `keytar`
module (libsecret/Secret Service) in `app.asar.unpacked`. The bundled keytar driver
is disabled by a platform check, not by any real incompatibility.

## Root cause (Joplin v3.7.21 source)

1. `packages/lib/shim-init-node.ts`:
   `const keytar = (shim.isWindows() || shim.isMac()) && !shim.isPortable() ? options.keytar : null;`
   → on Linux `shim.keytar()` returns `null`, so `KeychainServiceDriverNode.supported()`
   (`return !!shim.keytar?.()`) is `false`.
2. `packages/lib/BaseApplication.ts` registers drivers in the order
   `[KeychainServiceDriverElectron, KeychainServiceDriverNode]`
   → electron-safeStorage always wins when available.
3. `packages/lib/services/SettingUtils.ts`:
   `if (shim.isLinux() && !Setting.value('featureFlag.linuxKeychain')) KeychainService.instance().readOnly = true;`
   → on Linux the keychain is read-only unless the feature flag is enabled.
4. The electron driver only stores a `safeStorage`-encrypted blob; the system keychain
   holds the Chromium OSCrypt key — hence "Chromium Safe Storage" entries in KWallet.

## Solution

Three exact byte-level changes in both `main.bundle.js` and `main-html.bundle.js`
inside `app.asar`:

| # | Change | Effect |
|---|--------|--------|
| 1 | `.keytar:null` → `.keytar:require('keytar')` | keytar shim returns the bundled module on Linux instead of `null` |
| 2 | `return!!(` → `return!1&&!!(` (in `canUseSafeStorage`) | electron-safeStorage driver reports unsupported → skipped |
| 3 | `"featureFlag.linuxKeychain":{value:!1,` → `{value:!0,` | Linux keychain enabled by default (no `settings.json` edit needed) |

Resulting chain:

    Joplin → KeychainService → node-keytar → libsecret / D-Bus (org.freedesktop.secrets) → KeePassXC

## Patch script

`patch-joplin-keytar.sh` extracts the ASAR, applies the three changes with
exact-occurrence validation, checks JS syntax (`node --check`) and repacks.
It never modifies the original ASAR.

Requirements: Linux, Node.js, `npx @electron/asar`, Python 3.

    chmod +x patch-joplin-keytar.sh
    ./patch-joplin-keytar.sh /usr/lib/joplin-desktop/app.asar ./app.asar.patched

### Install / rollback

    sudo cp /usr/lib/joplin-desktop/app.asar /usr/lib/joplin-desktop/app.asar.orig   # once
    sudo cp ./app.asar.patched /usr/lib/joplin-desktop/app.asar

    # rollback:
    sudo cp /usr/lib/joplin-desktop/app.asar.orig /usr/lib/joplin-desktop/app.asar

> ⚠️ Package updates (e.g. `pacman -S joplin-desktop`) overwrite `app.asar` —
> re-apply the patch after each update.

### Prerequisite: KeePassXC Secret Service

KeePassXC must expose `org.freedesktop.secrets`
(Tools → Settings → Secret Service Integration; database unlocked/exposed):

    busctl --user list | grep -i secrets

### Testing from a custom directory (important)

A patched ASAR cannot run standalone from an arbitrary folder:
`ElectronAppWrapper.buildDir()` requires a real sibling `build/` directory, and
native modules resolve into `app.asar.unpacked/`:

    cp -a /usr/lib/joplin-desktop/build             ./test-dir/
    cp -a /usr/lib/joplin-desktop/app.asar.unpacked ./test-dir/
    cp ./app.asar.patched                           ./test-dir/app.asar
    electron ./test-dir/app.asar --disable-gpu-sandbox

Missing `build/` → crash: `Could not call remote method 'buildDir' ... Cannot find build dir`.

## Validation

Runtime log (`~/.config/joplin-desktop/log.txt`):

    KeychainService: Driver unsupported:electron-safeStorage   ← safeStorage disabled
    KeychainService: checking if keychain supported
    KeychainService: tried to set and get password. Result was: mytest   ← keytar works

Also: no `ERROR:kwallet_dbus` lines in the terminal, no new KWallet entries, and a new
entry appears in KeePassXC when saving the master password (Settings → Encryption).

### Troubleshooting

| Symptom | Cause |
|---|---|
| `Cannot find build dir` crash | missing sibling `build/` or `app.asar.unpacked/` (see above) |
| `Driver unsupported:node-keytar` persists | change #1 did not match (bundle layout changed) |
| no `unsupported:electron-safeStorage` + kwallet errors | change #2 did not match |
| `Starting KeychainService in read-only mode` | change #3 did not match |
| `Result was: undefined` | KeePassXC Secret Service not responding |

## Alternative (no patching)

Keep safeStorage but force its backend to libsecret by passing the switch **after**
the app path — Joplin's flag whitelist (`packages/lib/utils/processStartFlags.ts`)
rejects it with "Unknown flag" when placed before the path:

    electron /usr/lib/joplin-desktop/app.asar --password-store=gnome-libsecret

plus enabling `featureFlag.linuxKeychain`. KeePassXC then holds the OSCrypt key, but
the encrypted password remains in Joplin's local database (KvStore) — less direct
than the keytar chain patched here.

## Upstream

This patch is a workaround. Proper fixes for laurent22/joplin would be:

- wire `shim.keytar` on Linux (the Windows/macOS-only check in `shim-init-node.ts`
  is the only blocker);
- and/or whitelist `--password-store=` in `processStartFlags.ts`
  (precedent: `--enable-wayland-ime`, laurent22/joplin#10345);
- revisit the forced read-only Linux default in `SettingUtils.ts`.

## Reproducibility

SHA-256 of the ASARs used during validation (Joplin 3.7.21):

- original: `aa1a5f0a9c8b96e9a8ae3688ec7b33cbf80e5e24680aaa51a0b94a9c264e9ea3`
- patched:  `0cd852e9a5f1d835f009bb897b6c653fc14700affee9493d86a3df7411958e42`

Not required for other builds — the script validates every change with an
exact-occurrence check and fails loudly if the bundle layout changed.

## Scope & license

Patch and documentation only; contains no Joplin build artifacts (Joplin itself is
MIT-licensed — the ASAR is produced from your own installation). Depends on Joplin's
internal bundle layout; may need adjustment for other versions. MIT.
