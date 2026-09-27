---
name: deploy-pmm-everywhere
description: Build, sign, install, launch, and verify Package Manager Manager on Max's local Mac and pangolin over SSH. Use for requests to deploy PMM everywhere or refresh both personal Mac installations from this checkout.
---

# Deploy PMM Everywhere

Adapted from Portal's deploy-everywhere skill. PMM has only a macOS app, so the targets are this Mac and `pangolin`; there is no iPhone build. This is a personal installation workflow, not a GitHub release or website deployment.

Run from the requested PMM checkout:

```bash
./scripts/deploy-everywhere.sh
```

The script uses the existing release build and signing pipeline, installs and launches locally, then stages and verifies the same app on `pangolin` before replacing its installation. PMM's menu-bar helper and `pmmctl` are embedded in the bundle. It checks code signatures, compares all three executable hashes, and verifies the installed app and menu-bar helper are running on both Macs.

Deployment restarts `PMMApp` and `PMMMenuBar`. Preserve application support data, preferences, credentials, and remote-host configuration; Portal's session termination and tab-catalog deletion do not apply. Do not terminate active package operations or `pmmctl` workers to force a deployment; wait for them to finish. The script refuses to proceed while a `pmmctl` worker is running.

Use the existing signing identity selection. Personal installs do not require the build script's notarization credentials, so the deployment script runs it through Bash without the optional vault injection. Do not publish, bump versions, change signing settings, or erase caches to work around a failure.

Report success separately for this Mac and `pangolin`. If a step fails, retain successful installs, report the failed command and stage, and fix only a demonstrated deployment issue before retrying. A failed remote replacement restores the previous bundle; a remote launch failure leaves the verified new installation in place for diagnosis.
