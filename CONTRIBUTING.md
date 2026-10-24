# Contributing

Thanks for helping improve Bucket Manager.

## Build and test

```sh
swift build
./scripts/test.sh
```

`scripts/test.sh` runs the headless UI/model suite and the fake-S3 end-to-end
suite. The fake server does not need network access or real credentials.

## Guidelines

- Keep secrets out of the repository. Tests use the fake S3 server under
  `scripts/fake_s3.py`; never commit real access keys or bucket data.
- Preserve the account-only credential boundary: metadata may be written to
  Application Support, but secrets belong in Keychain.
- Update `CHANGELOG.md` for user-visible changes.
- Add or extend a regression check for behavior changes.
- Keep UI work keyboard-accessible and run the accessibility snapshot audit
  (`S3C_A11Y=1`) when changing custom controls.
- Follow the existing AppKit structure and `docs/ARCHITECTURE.md` conventions.

## Branching and releases

`main` is always releasable and protected: changes land only through a pull
request with a passing `verify` check, and force-pushes are blocked.

1. Branch from `main` with a type prefix: `fix/`, `feat/`, `docs/`, `ci/`,
   `chore/`, `refactor/`, or `test/` (for example `fix/empty-state-colors`).
2. Commit with one-line messages in the form `<type>: <description>`, under
   72 characters.
3. Open a pull request into `main` and wait for CI.
4. Squash-merge. The pull request title becomes the commit on `main`, so give
   it the same `<type>: <description>` form.
5. Release from `main` only, by tagging the merged commit:
   `macos-vX.Y.Z` for the macOS app and `windows-vX.Y.Z` for the Windows
   preview. The release workflows build and publish from the tag.

## Pull requests

Describe the problem, the change, and how it was verified. Include the exact
test commands and results. Avoid unrelated refactors in the same change.
