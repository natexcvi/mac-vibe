# Releasing MacVibe

Releases are cut by pushing a tag. The
[`Release` workflow](../.github/workflows/release.yml) builds, signs, notarizes,
packages and publishes everything, and updates the Sparkle feed that shipped
apps poll for updates.

```bash
git tag v0.2.0
git push origin v0.2.0
```

That produces a GitHub release containing:

| Asset | Purpose |
| --- | --- |
| `MacVibe-<version>.dmg` | notarized + stapled, what people download |
| `MacVibe-<version>.zip` | notarized + stapled, what Sparkle installs |
| `appcast.xml` | the EdDSA-signed update feed |

Running the workflow again for the same tag replaces the assets rather than
failing, so a release that dies halfway through can just be re-run.

## One-time setup

Everything below is stored as a GitHub Actions **repository secret**
(Settings → Secrets and variables → Actions).

### 1. Developer ID Application certificate

Notarization needs a *Developer ID Application* certificate — an "Apple
Development" certificate will not work.

1. In Keychain Access: **Certificate Assistant → Request a Certificate From a
   Certificate Authority**. Enter your email, pick *Saved to disk*, and save
   the `.certSigningRequest`.
2. At [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list),
   create a certificate of type **Developer ID Application**, upload the CSR,
   and download the resulting `.cer`.
3. Double-click the `.cer` to install it into your login keychain.
4. Confirm it is there and note the exact identity string:

   ```bash
   security find-identity -v -p codesigning
   ```

   You want the line reading `Developer ID Application: Your Name (TEAMID)`.

5. Export it for CI — in Keychain Access select the certificate **and** its
   private key, right-click → *Export 2 items…*, save as `.p12` with a strong
   password. Then:

   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | the base64 blob from above |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |

### 2. App Store Connect API key (for notarytool)

An API key is preferred over an Apple ID + app-specific password: it is
scoped, revocable, and doesn't carry your Apple ID.

1. At [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api),
   create a key with the **Developer** role.
2. Download the `.p8` — Apple lets you download it exactly once.
3. Note the **Key ID** and the **Issuer ID** shown on that page.

| Secret | Value |
| --- | --- |
| `APPLE_API_KEY_P8` | the entire contents of the `.p8` file |
| `APPLE_API_KEY_ID` | the Key ID |
| `APPLE_API_ISSUER` | the Issuer ID |

### 3. Sparkle signing key

Updates are signed with an EdDSA key that is pinned in `Info.plist` as
`SUPublicEDKey`. Sparkle refuses any update that doesn't verify against it, so
even someone who could replace the release assets could not ship a payload
your users would install.

The key pair for this repo already exists — the private key is in the login
keychain of the machine that generated it. To export it for CI:

```bash
./build/sparkle-2.9.6/bin/generate_keys -x sparkle_private_key.txt
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.txt
rm sparkle_private_key.txt
```

| Secret | Value |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | the exported private key |

> **Back this key up.** Losing it means shipped copies of MacVibe can never be
> auto-updated again — every user would have to reinstall by hand, because the
> new public key wouldn't match the one baked into their build.

To generate a fresh pair (only for a new project — see the warning above):

```bash
./build/sparkle-2.9.6/bin/generate_keys
```

and put the printed public key into `SUPublicEDKey` in `Resources/Info.plist`.

## Releasing from your own machine

Useful for testing the pipeline without pushing a tag. Store the notarization
credentials in a keychain profile once:

```bash
xcrun notarytool store-credentials macvibe-notary \
  --key ~/private_keys/AuthKey_XXXXXXX.p8 --key-id XXXXXXX --issuer <issuer-uuid>
```

then:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=macvibe-notary \
VERSION=0.2.0 \
./scripts/release.sh
```

The private Sparkle key is read from your login keychain, so `SPARKLE_KEY_PATH`
isn't needed locally.

## Versioning

`build.sh` stamps two numbers into `Info.plist`:

- **`CFBundleShortVersionString`** — the marketing version, from the tag
  (`v0.2.0` → `0.2.0`).
- **`CFBundleVersion`** — the commit count (`git rev-list --count HEAD`). This
  is what Sparkle compares to decide whether an update is newer, so it must
  increase with every release. Because it counts commits, it does so on its
  own as long as releases move forward.

## Verifying a release

```bash
spctl --assess --type execute --verbose=2 /Applications/MacVibe.app
xcrun stapler validate /Applications/MacVibe.app
```

Both should report acceptance. To test the update path end to end, install an
older version and choose **Check for Updates…** from the menubar.
