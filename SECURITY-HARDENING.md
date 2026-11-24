# Security hardening candidate — 2026-11-24

Based on upstream v1.6.11, commit e1de0a002d7e6643194635ac04cc02bd75c4fe0e.
This is a source review candidate, not a security certification or a signed release.

## Changes

- PAM requires a provisioned authentication key for every approval. Missing or
  unusable keys return PAM_IGNORE before any connection to the user-owned socket;
  the remaining configured macOS authentication methods handle the request.
  A bare OK can never approve a request. Strict MAC parsing rejects trailing data.
- Enabling sudo or GUI authorization in Features first provisions the verification
  key if needed. The security banner explains why fingerprint approval is unavailable.
  Removing the key disables fingerprint PAM rather than downgrading authentication.
- New-install screen unlock, Passwords autofill, SSH agent, CLI operations and
  Quick Fill default off. Existing explicit preferences are preserved. Configuring
  a login password in the wizard prepares screen unlock; Done enables it only after
  its remaining prerequisites are complete.
- Setup explains that the app can retrieve the login password from Keychain and
  enter it via Accessibility. The existing skip-password step remains available.
- Automatic app/firmware update checks are opt-in with an explanation of destinations.
  The update window respects that preference, including when opened automatically
  for old firmware. Explicit Check buttons still work. Users who disable automatic
  checks must check manually to receive security fixes. Downloads already requested
  are not canceled by changing this preference.
- Preventing idle system sleep is opt-in, with the power/reconnection tradeoff stated.
  Changing the preference releases an existing sleep assertion. This does not fix
  Bluetooth HID reconnect wakeups in the firmware/OS.
- Paired-device verification uses a new challenge on each connection; a remembered
  Bluetooth UUID no longer bypasses the challenge.
- Added PAM policy tests, stricter MAC tests, default-preference tests, a pull-request
  test workflow, and tests before the existing release workflow signs/publishes.
- New UI copy is English, including explicit English entries in JSON language packs;
  translations and native-language layout review remain pending.

## Deployment requirements

Do not install this as an unsigned substitute for the official release. No installer
or distributable app is supplied. Applying source patches is not deployment.
The PAM binary must be rebuilt and shipped with the patched app; replacing only
app source or an app bundle does not fix an already installed vulnerable PAM module.

Preferred delivery is a vendor-reviewed release, signed and notarized by the vendor.
A separately maintained fork needs its own signing identity and carefully updated
peer-signature/update trust configuration. CLISources/PeerCodeSignature.swift and
Sources/AppUpdateService.swift currently pin the vendor's identity. Do not bypass
signature verification with --allow-unsigned-app or disable Gatekeeper to deploy.
An official app update can overwrite these fixes until they are adopted upstream.

## Remaining security work — release blockers for a broad security claim

1. Fresh, request-bound device approvals require a versioned firmware/app protocol:
   authenticate a nonce, session, operation, host identity and request digest; consume
   each approval once; reject old protocol versions for protected operations. The
   existing fingerprint 0x21 message authenticates only its type and fingerprint ID.
   A fresh connection challenge does NOT fix replay of that message within a session.
2. Review and replace service/time-scoped PAM preauthorization with process/request-
   bound authorization. The 3-second GUI and 10-second agent bridges must not allow
   a concurrent unrelated request to consume an intended approval. Device-side
   secret-read cooldown/budgets and host authentication need firmware review too.
3. Password autofill necessarily exposes plaintext to the app during use. Keychain
   storage and signed-target checks reduce risk but do not create native Touch ID
   isolation. Keep vault master passwords and Apple-account passwords out initially.
4. Audit firmware signing/rollback enforcement, boot chain, pairing, sensor matching,
   enrollment authorization, physical extraction/tamper handling and hardware keys.
   None of these are established by the Mac patch or Apple notarization.
5. Exercise a signed build on real hardware: provisioning/cancel/error flows, paired
   reconnects, lock/unlock and password changes, multi-user sessions, sleep/wake,
   uninstall/upgrade/rollback, managed Macs and all supported OS/CPU combinations.
6. Add protocol parser fuzzing, socket concurrency/fragmentation tests and an
   independent security assessment. Full Swift tests and visual UI verification
   must pass before releasing.

## Validation

See docs/DESKTOP-EXPERIENCE-REVIEW.md for current implementation and validation results.
The PAM policy test stubs only key loading, socket creation and audit output while
executing the actual authentication function. It never installs PAM or alters the
host's authentication settings. Existing crypto tests cover valid/invalid MACs;
new cases cover a changed request nonce and trailing bytes.

Safe developer checks on a Mac with a complete compatible Xcode toolchain:

```sh
make -C pam test
swift test --build-system native
swift build -c release --build-system native
```

Do not run packaging/test-pam-spoof.sh on a production Mac as an ordinary unit test:
it stops the installed app and replaces the real user socket.
