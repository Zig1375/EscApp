# Release notes

One file per release, named after its tag: `v<version>.md` (for example `v1.0.7.md`; `scripts/next-version.sh`
prints the next version). Commit it together with the change it describes, before pushing to `main`: every push to
`main` becomes a release, and the release job refuses one that has no notes. The job puts the file at the top of
the release, followed by the zip's SHA-256 and size, which it adds itself, and Sparkle shows the same text in its
update window.

Write what changed for players and what to watch for, not how the code works; commit messages and the code explain
that. Each change gets a bold first sentence saying what is different now, then why and what it means in practice.
