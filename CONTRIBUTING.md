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

## Pull requests

Describe the problem, the change, and how it was verified. Include the exact
test commands and results. Avoid unrelated refactors in the same change.
