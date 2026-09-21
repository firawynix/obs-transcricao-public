# Code-signing policy

Official Windows artifacts are built from the public source commit by GitHub
Actions. The workflow records the repository, commit and SHA-256 hashes next to
the unsigned artifacts.

When SignPath Foundation approval is available, only artifacts produced by this
public workflow may be submitted for signing. Signed output must be traceable to
the same public commit and must not contain private source, secret configuration,
recordings, models or binaries that are absent from the documented build process.

Microsoft Store packages, when offered, are signed and distributed by Microsoft.
