# FRANZFON ARM64 Installer

The native ARM64 installation is intentionally split into reversible stages:

1. `franzfon-arm64-prepare.sh` extracts a sanitized application payload from the official appliance.
2. `franzfon-arm64-install-app.sh` installs the application and rebuilds Node.js dependencies natively.
3. `franzfon-arm64-normalize-native-addons.sh` verifies native Node.js addons as AArch64.
4. `franzfon-arm64-install-asterisk.sh` builds Asterisk 22.7.0 and publishes its required runtime data, including XML documentation.
5. `franzfon-arm64-bootstrap.sh` creates fresh local configuration and is the only stage that can activate services with `--activate`.

Runtime directories such as `/data`, `/backup`, `/backups` and `/config` are excluded only at the FRANZFON payload root. Nested application data, including the holiday module used by the backend, remains part of the sanitized payload and is validated before publication.

The bootstrap creates both Asterisk and FRANZFON database users, provides the custom PJSIP include expected by the application, and tolerates the intentional Asterisk restart performed during FRANZFON first boot. Service activation is accepted only after the web interface responds and Asterisk passes multiple consecutive health checks.

No existing passwords, databases, machine identity or license state are imported. The original application licensing mechanism is preserved and is not bypassed.
