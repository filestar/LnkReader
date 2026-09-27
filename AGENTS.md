# AGENTS.md — LnkReader

Keep this file current.

## Publishing

The NuGet package `LnkReader.Net6` is published only by `./Publish.ps1` (dry run) then `./Publish.ps1 -Execute`, to the
Sliplane feed `filestar-nugets.sliplane.app`, which `filestar/Filestar` restores from. It packs the commit on
`origin/master`, never the working tree, refuses a version already on the feed, and reads the package back to
compare hashes. The push key comes from Dopbase `filestar-tools/production`.

`azure-pipelines.yml` (Azure DevOps pipeline 28) was removed on 2026-09-27: it pushed every push to `master` and
every pull request to the old Azure feed, with the push key written into the file.

A new version reaches customers only when a plugin in `filestar/Filestar` takes it (`dotnet add package`), bumps
its own version, and is released. Dependency versions come from the package manager, never typed by hand.
