# Security findings (out of scope to fix here)

This branch only builds `cca-infra`. It does **not** modify `cca_backend`,
`cca_frontend`, or `cca_admin_frontend` - those are the app owner's repos and
credential rotation there is their call to make and execute, not something
to do silently as a side effect of an infra PR. This document exists so the
findings aren't lost, and lists concrete rotation steps for when you're
ready to act on them. Nothing below reproduces an actual secret value.

## `cca_backend`

Its `Dockerfile` (as of the commit vendored into this repo's
`cca_backend` submodule) hardcodes real-looking values via `ENV`
instructions for: MongoDB Atlas credentials (user/password/host/database),
a Redis connection URL (a Render.com-hosted instance), a JWT signing key,
Firebase project identifiers, and Razorpay API keys (test-mode, `rzp_test_*`
- lower risk than live keys, but still shouldn't be hardcoded). `/system_env.sh`
additionally contains a live `MONGO_CUSTOM_URL` with embedded Atlas
credentials, plus its own JWT and Razorpay values.

Also tracked in git: `/env/.env`, `/env/.env_prod`, and
`/env/cca-vijayapura-firebase-adminsdk-ghz2d-1f8e7ad071.json` - the last one
is a **Firebase service-account private key**, which is a credential in the
fullest sense (it can mint admin tokens against that Firebase project).

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
