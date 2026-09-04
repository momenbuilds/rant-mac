# Security policy

## Reporting a vulnerability

Open a **private security advisory** on the GitHub repository
(Security → Report a vulnerability). Please do not open a public issue for anything
that could be used against a user before there is a fix.

Include what you did, what happened, and what you expected. A proof of concept
helps; a working exploit is not required and please do not attach one to a public
thread.

Expect an acknowledgement within a few days. Rant is a small open-source project
with no paid security team, so please be realistic about response times — but
anything affecting the refusals listed below is treated as urgent.

## What we consider a vulnerability

These are the guarantees the product makes. A way to break any of them is a
security bug, not a feature request:

1. An API key leaving the Keychain — appearing in a log, a preference file, a crash
   report, a network request to anyone but its own provider, or the UI in plaintext
   when not being edited.
2. Transcript or context text appearing in system logs at default level.
3. Reading from or writing into a secure text field.
4. Audio or text reaching the network when the local provider or "local only" is
   selected.
5. Context marked local-only appearing in an outbound request.
6. A credential-shaped string surviving `SecretRedactor` into an outbound request.
7. Migration writing to, deleting, or decrypting data belonging to another app.
8. The local MCP server binding a non-loopback interface, exposing a collection the
   user did not enable, or exposing secrets.
9. A voice command causing a filesystem, shell or network side effect without the
   documented confirmation step.
10. Retained audio surviving past its configured retention window.

## Not vulnerabilities

- A local process running as your user reading `~/Library/Application Support/Rant/`.
  That is the macOS security model; see `docs/THREAT_MODEL.md`.
- Your chosen cloud provider being able to read what you dictated to it.
- Rant requiring Accessibility permission. That is what typing into other apps is.

## Supported versions

Pre-1.0, only the latest release is supported.
