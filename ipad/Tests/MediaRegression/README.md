# Native media regression

Run from the repository root on macOS with Xcode installed:

```sh
python3 ipad/Tests/MediaRegression/run.py
```

The runner compiles the production storage and playback engines with their shared directory and manifest helpers, then runs bounded tests using temporary, synthetic WAV files. It does not open the simulator, access an iPad, or change the user’s library. AVFoundation media services and coordinated local file reads must be available to the process.

Coverage includes:

- The production default-root path, using an isolated Application Support directory. On a case-insensitive volume, a historic `Nomad` directory is opened with its existing spelling; a case-sensitive volume keeps the exact `NOMAD` path. Loading preserves the original manifest, copied media, and progress. Playlist writes survive a fresh store instance.
- A symlink in the default-root hierarchy fails closed without changing the existing library; removing that test-owned symlink permits a clean reload.
- Real WAV metadata and independent imports, AVPlayer seek/resume, saved progress after reopening, actual playback completion, playlist auto-next, and reset.
- Failed progress/deletion persistence, interrupted deletion recovery, playlist pruning, corrupt-manifest preservation, and version-one archive migration.

The default-root regression exercises the production branch through `supportDirectoryURL`; it does not substitute the direct `rootURL` test path. Its Foundation/macOS coverage supplements the simulator regression for the shared resolver. Physical iPad subtitle/audio-track selection, video codecs, scrubbing, and interruption behavior remain separate device acceptance checks.
