# Security findings (out of scope to fix here)

This branch only builds `cca-infra`. It does **not** modify application
source in `cca_backend`, `cca_frontend`, or `cca_admin_frontend` - those are
the app owner's repos and credential rotation there is their call to make
and execute, not something to do silently as a side effect of an infra PR.
(The one exception, added with explicit confirmation, is a single additive
CI file - `.github/workflows/notify-cca-infra.yml` - pushed to all three for
push-triggered auto-deploy; see IMPLEMENTATION_PLAN.md §15. It touches no
application code or secrets.) This document exists so the findings aren't
lost, and lists concrete rotation steps for when you're ready to act on
them. Nothing below reproduces an actual secret value.

## `cca_backend`

Its `Dockerfile` (as of the commit vendored into this repo's
`cca_backend` submodule) hardcodes real-looking values via `ENV`
instructions for: MongoDB Atlas credentials (user/password/host/database),
a Redis connection URL (a Render.com-hosted instance), a JWT signing key,
Firebase project identifiers, and Razorpay API keys (test-mode, `rzp_test_*`
- lower risk than live keys, but still shouldn't be hardcoded). `/system_env.sh`
additionally contains a live `MONGO_CUSTOM_URL` with embedded Atlas
credentials, plus its own JWT and Razorpay values.

Separately: pushing to this repo's `main` (to add the notify workflow above)
surfaced a GitHub Dependabot alert - 32 vulnerabilities on its default
branch (10 critical, 8 high, 13 moderate, 1 low) as of this writing. Not
investigated or fixed here (dependency remediation in `cca_backend` is
application work, not infra), but worth acting on before this ships real
user data - see `https://github.com/brguru90/cca_backend/security/dependabot`.

Also tracked in git: `/env/.env`, `/env/.env_prod`, and
`/env/cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json` - the last one
is a **Firebase service-account private key**, which is a credential in the
fullest sense (it can mint admin tokens against that Firebase project).

Lower severity, but worth knowing about: `src/my_modules/google_cloud.go`
hardcodes a real Google Cloud project ID, zone, and Compute Engine instance
name (used to start/stop a VM for video processing - see
IMPLEMENTATION_PLAN.md §14). This deployment never calls that code path
successfully (no GCP credentials are configured here, so it fails cleanly
and harmlessly - see §14), but the identifiers themselves are still exposed
in a public repo. Not something this branch can fix without editing the
submodule.

**Rotation checklist** (do this before pointing `cca-infra` at real user
data, not after):
1. Rotate the MongoDB Atlas user's password; update the `MONGO_ADMIN_PASSWORD`
   GitHub secret per environment (this project creates its own MongoDB
   users via the MongoDB Community Operator, so Atlas is only relevant if
   you're migrating existing data in rather than starting fresh - see
   `terraform/app/mongodb.tf`).
2. Rotate the JWT signing key; update the `JWT_SECRET_KEY` GitHub secret per
   environment. Note: rotating this invalidates every existing session/token.
3. Regenerate a Firebase service-account key from the Firebase console,
   revoke the old one, and set the new JSON's content as the
   `FIREBASE_SERVICE_ACCOUNT_JSON` GitHub secret per environment.
4. Rotate the Razorpay keys (even the test ones, as good hygiene) and update
   `RAZORPAY_KEY_ID`/`RAZORPAY_KEY_SECRET` per environment.
5. In `cca_backend` itself (separate repo, separate PR, not this branch):
   remove the hardcoded `ENV` values from the Dockerfile, remove
   `/env/.env`, `/env/.env_prod`, and the Firebase JSON from git, and add
   them to `.gitignore` (currently only `go.sum`/`go_server`/etc. are
   ignored - `env/` is not). Rotating the values alone doesn't remove them
   from git history; a new commit that deletes them still leaves them
   recoverable from history unless you rewrite it.

## `cca_admin_frontend`

Correction to the earlier planning docs: `initial-plan.md` flagged this
repo's committed `.env`/`.env_prod` files as a secrets leak. Reading them
directly shows they contain no credentials - just a `BASE_URL` pointing at
`http://127.0.0.1:8000/`, a local development placeholder, and (per
IMPLEMENTATION_PLAN.md §1) that variable isn't even consumed by the
production build. No rotation action needed here.

## `cca_frontend`

`android/app/keystore.jks` (the release signing keystore) **and**
`android/key.properties` (its passwords, in cleartext) are both tracked in
git. Any APK signed with this keystore is signed with a key anyone can
extract from the public repository - `flutter build apk --release` in
`.github/workflows/deploy.yml` will happily use it if no alternative is
configured, which is why that workflow prints a `::warning::` annotation
every time it falls back to it.

Also present (lower severity - Firebase/Facebook client-side config is
designed to ship inside every app install and isn't a secret in the same
sense as a private key, but is still worth being deliberate about):
`android/app/google-services.json`, `lib/firebase_options.dart`, a Facebook
client token in `android/app/src/main/res/values/strings.xml`, and a
Razorpay **test-mode** key hardcoded in two widget files.

**Rotation checklist**:
1. Generate a new release keystore (`keytool -genkeypair ...`) - do this
   once, offline, and never commit it.
2. Base64-encode it and set it as the `ANDROID_KEYSTORE_BASE64` GitHub
   secret (repository-level, not per-environment - see
   IMPLEMENTATION_PLAN.md §8); set the matching `key.properties` content as
   `ANDROID_KEY_PROPERTIES`.
3. If this app has ever been published with the old keystore, work with
   your distribution channel (Play Console app signing, direct APK
   distribution, etc.) on a key-rotation path - Android's own key rotation
   mechanics are out of scope for this document.
4. In `cca_frontend` itself (separate repo, separate PR): remove
   `android/app/keystore.jks` and `android/key.properties` from git and add
   them to `.gitignore`; same history caveat as above applies.
