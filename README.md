# Restoring Linux Secret Service / KeePassXC Support in Joplin

A reproducible patch to restore Joplin's existing `node-keytar` / Secret Service path on Linux.

## Problem

On Linux, Joplin may select Electron's `safeStorage` backend while its bundled `node-keytar` implementation is available. In the tested environment this resulted in:

```
KeychainService: Driver unsupported:electron-safeStorage
```

The Joplin application already contained the Linux `keytar` module. The solution is to restore the existing Linux keychain path and prevent Electron SafeStorage from being selected.

## Solution

The patch makes three targeted changes in both:

- `main.bundle.js`
- `main-html.bundle.js`

### 1. Enable the existing keytar module

Change:

```js
.keytar:null
```

to:

```js
.keytar:require('keytar')
```

This supplies Joplin's keychain driver with the bundled `node-keytar` implementation on Linux.

### 2. Disable the SafeStorage capability path

Change the beginning of the targeted `canUseSafeStorage` return expression:

```js
return!!(
```

to:

```js
return!1&&!!(
```

This prevents Electron SafeStorage from being considered usable by this code path.

### 3. Enable Joplin's Linux keychain feature flag

Change:

```js
"featureFlag.linuxKeychain":{value:!1,
```

to:

```js
"featureFlag.linuxKeychain":{value:!0,
```

This restores the Linux keychain path that is otherwise disabled.

## Patch script

`patch-joplin-keytar.sh` extracts an existing Joplin `app.asar`, applies the three exact changes to both bundles, validates JavaScript syntax, and creates a new patched ASAR.

It does not redistribute Joplin binaries or overwrite the original ASAR.

### Requirements

- Linux
- Joplin installed as an Electron application
- Node.js
- `npx asar`
- Python 3

Example:

```bash
chmod +x patch-joplin-keytar.sh
./patch-joplin-keytar.sh /usr/lib/joplin-desktop/app.asar ./app.asar.patched
```

After verifying the generated file, replace the installed ASAR with the patched one according to your distribution's installation layout.

## Validation

The patched ASAR was tested on Arch Linux with KeePassXC.

The runtime validation produced:

```
KeychainService: Driver unsupported:electron-safeStorage
KeychainService: checking if keychain supported
KeychainService: tried to set and get password. Result was: mytest
```

The important result is the successful set/get test through the `node-keytar` path.

The Secret Service chain is therefore:

```
Joplin
  -> KeychainService
  -> node-keytar
  -> Secret Service / D-Bus
  -> KeePassXC
```

## Reproducibility

The original ASAR was preserved separately during development.

Original SHA-256:

```
aa1a5f0a9c8b96e9a8ae3688ec7b33cbf80e5e24680aaa51a0b94a9c264e9ea3
```

Patched test ASAR SHA-256:

```
0cd852e9a5f1d835f009bb897b6c653fc14700affee9493d86a3df7411958e42
```

These hashes identify the exact files used during the original validation and are not required for applying the patch to another Joplin build.

## Scope

This repository contains the patch and documentation only. It does not contain Joplin's proprietary application files.

The patch relies on the internal structure of the Joplin Electron bundles and may need adjustment when Joplin changes its bundled JavaScript.

## License

MIT
