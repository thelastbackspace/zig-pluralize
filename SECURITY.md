# Security

This package is pure parsing and formatting logic: no network, no
filesystem, no cryptography. The realistic risk classes are correctness
bugs — wrong results, panics on crafted input, or undefined behavior.

Please report vulnerabilities through GitHub's private vulnerability
reporting (Security tab → Report a vulnerability) instead of a public
issue. Include a minimal reproducing input and the Zig version.

Wrong-output reports that are clearly not security-sensitive can go
straight to Issues.
