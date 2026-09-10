fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios bootstrap

```sh
[bundle exec] fastlane ios bootstrap
```

Register the bundle id (idempotent). The app record itself needs a web session once.

### ios bootstrap_app

```sh
[bundle exec] fastlane ios bootstrap_app
```

Create the App Store Connect app record via an Apple ID web session (fastlane spaceauth first).

### ios prep_signing

```sh
[bundle exec] fastlane ios prep_signing
```

Fetch the Distribution cert + App Store profile (manual signing for Release).

### ios tf_status

```sh
[bundle exec] fastlane ios tf_status
```

Processing + compliance state of the latest TestFlight build.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
