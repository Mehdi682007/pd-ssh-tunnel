# Changelog

## 2.1.0

- Add an explicit foreign-initiated reverse-egress wizard in main-menu option 4.
- Refuse to overwrite an existing initiator configuration during reverse setup.
- Document the difference between SSH connection direction and forwarded traffic direction.
- Remove the recording guide from current public documentation.

## 2.0.0

- Fix inverted success/failure condition in automatic SSH key installation.
- Derive the public key from the existing private key before every installation.
- Reuse one administrative SSH connection, with backups and authentication-failure rollback.
- Verify SSH authentication using a control connection instead of matching a login message.
- Synchronize destination PermitOpen/PermitListen with configured forwards.
- Add diagnostics, repair, application tests, throughput comparisons, forward export/import and a 3x-ui guide.
- Validate forwarding inputs and check local port conflicts before saving.
- Add CLI actions and batch setup for pre-provisioned SSH trust/admin authentication.
- Select cipher preference using CPU AES support; keep OpenSSH's default rekey limits.
- Apply only the manager's sysctl file when enabling the performance profile.
- Add regression tests, isolated sshd tests, key-installer tests and CI.
- Preserve the English terminal UI and bilingual documentation.

## 1.4.0

- Initial public release with local/reverse forwards, autossh, systemd and an optional performance profile.

## Compatibility

Version 2.0 supports the original plain reverse-forward records and L/R-prefixed records.
After upgrading, use Repair to synchronize the destination key/port policy and regenerate the runner.
Existing connections will reconnect during this operation.
