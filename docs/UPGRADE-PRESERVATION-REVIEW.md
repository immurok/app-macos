# Upgrade preservation: review findings and proposed contract

Reviewed app-macos PR #21 at `67de871b969bbe12daae3702eb603915c12dba5e`
and homebrew-tap PR #1 at `15713207bb8aa65db842f136826354dfc1e410c9`.
This is a proposal for the packaging contributor, not a shipped packaging change.

## Confirmed failure

The cask runs privileged `touch /tmp/immurok-keep-user-data` then unconditionally
executes the uninstall package. A directory at that path makes `touch` succeed,
but the package's `-f` check fails and it removes the PAM key and user data.
The regular-file and symlink-to-file cases preserve data. There is no owner,
freshness, or transaction check. A failed marker creation does not stop the cask.

Reproduce only with an isolated copy of the proposed script:

```sh
python3 docs/review-tools/reproduce-upgrade-marker.py /path/to/pr21/packaging/uninstall-postinstall
```

All installer paths are redirected through `IMMUROK_ROOT` to a temporary fake
filesystem. The script under review must honor that test seam. The reproduction
never invokes installer, sudo, the real cask, or the production PAM stack.
Observed directory case: exit 0, key deleted, marker directory remains.

## Proposed replacement: explicitly selected signed packages

Avoid introducing a marker protocol at all:

1. Build a second signed/notarized, no-payload package named
   `immurok_preserve_uninstall.pkg`. Its preservation behavior must be fixed
   inside its signed postinstall script, not inferred from an environment
   variable, argument file, global marker, or the invoking user's identity.
2. Generate both package scripts from the same source at build time. Use an
   explicit build-time mode: preserve vs full removal. Preserve mode must keep
   all user data, preferences and PAM key bytes, metadata, and permissions;
   skip Keychain cleanup. Both modes retain the existing PAM-reference checks
   and abort/rollback behavior. In-app explicit full uninstall retains its
   existing package and user-Keychain cleanup path.
3. Bundle/sign both before app signing and install an external copy of each,
   using the existing external uninstaller arrangement. Homebrew selects only
   the preservation package. It must not fall back to the old full-cleanup
   package if preservation support is missing or fails.
4. Keep the package invocation mandatory (`must_succeed: true`). An invalid or
   unsupported preservation path must stop before receipt-based deletion.
   Do not remove the PAM module while any configuration still references it.
5. Provide explicit full-removal instructions. If using `sudo imk pam-key remove`,
   run it while the CLI is still installed; do not prescribe that command after
   uninstall has removed it. Document that Homebrew zap cannot by itself remove
   the root-owned key and does not clear the app's user Keychain entries.

This requires coordinated app/cask releases and maintainer agreement. Changing
only the new cask does not fix the first upgrade: Homebrew may execute the
previously installed cask and uninstaller. Provide a tested migration procedure
before telling existing users to upgrade/reinstall. Do not promise automatic
preservation for that transition. Also document that the present approach still
removes/re-adds PAM entries and does not preserve a user-customized PAM ordering.

## Acceptance checks for the packaging changes

- Assert byte-for-byte preservation of real 32-byte `.key` fixtures, key ID,
  preferences and `.immurok` content, including modes and owner where applicable.
- Test preserve vs explicit full-removal packages independently; filesystem
  marker files/directories/symlinks must have no influence on either mode.
- Test missing preservation package, denied PAM writes, failed new installation,
  interruption and retry. No fallback may silently select full removal.
- Existing safety checks must still prevent a dangling PAM module reference.
- Run a signed upgrade on a disposable Mac/VM with both new and legacy installed
  casks; assert settings, key agreement and password fallback after each stage.
- Exercise preferences commands and Keychain lifecycle in native acceptance;
  fake-root tests intentionally skip those system operations.

## PAM follow-up in PR #18

`pam/test_pam_socket.c` drives the production authentication function with a real
Unix listener and real key loader in a temporary home. It checks missing,
wrong-length, symlinked and overly readable key files without socket contact;
then checks bare OK, a MAC from a different 32-byte key, a stale nonce, and a
valid fresh MAC. Identity paths, terminal output and logging are isolated.
The test does not install a PAM module or execute an authentication prompt.

The distinction matters: after PR #18, loss of the root key disables this module
and returns to the remaining PAM stack. It does not re-enable unsigned approval.
PR #21 protects configuration continuity; PR #18 removes the compatibility bypass.
