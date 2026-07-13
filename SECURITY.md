# Security policy

Report suspected vulnerabilities through GitHub's private vulnerability reporting form:

https://github.com/oliverames/ping-warden/security/advisories/new

Do not open a public issue. Include the affected Ping Warden and macOS versions, reproduction steps, and the impact you observed. If the report involves the privileged helper or updater, describe the trust boundary that was crossed. Leave out credentials and unrelated personal data.

I will acknowledge reports as soon as I can. Confirmed vulnerabilities will be prioritized by severity, then documented after users have had a reasonable chance to update.

## Supported versions

Security fixes are issued for the current public release. Update through Ping Warden or download the latest notarized release from GitHub.

## Release integrity

Public releases are signed with Oliver Ames's Apple Developer ID, notarized by Apple, and distributed in a signed disk image. Sparkle update archives and feeds use EdDSA signatures. If macOS or Ping Warden reports an invalid signature, stop the installation and file a private report.
