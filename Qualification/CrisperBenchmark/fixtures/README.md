# Local qualification assets

Place the four audio files and their hand-labeled reference JSON files at the
paths declared by `../corpus-manifest.v1.json`. These assets are intentionally
not committed: the repository currently contains neither an agreed redistributable
speech corpus nor authorization to publish a Speaker's recordings.

Before a qualification run, replace each manifest's null hashes with SHA-256
digests and set `assetStatus` to `ready`. A reference file has this shape:

```json
{
  "schemaVersion": 1,
  "fixtureId": "short",
  "durationMs": 18420,
  "lastSpeechEndMs": 17910,
  "words": ["we", "[um]", "we", "we", "need", "to", "start"],
  "beginningAnchors": [["we", "[um]", "we"]],
  "tailAnchors": [["need", "to", "start"]],
  "verbatimEvents": [
    {"kind": "filled-pause", "words": ["[um]"]},
    {"kind": "immediate-repetition", "words": ["we", "we"]}
  ]
}
```

The hand label must describe the recording that was actually captured; it is not
an edited reading script. Keep cutoffs as trailing-hyphen tokens and keep explicit
Crisper event tags such as `[um]` and `[laughter]` as individual words. Each
required phenomenon in the manifest must have a matching labeled event or anchor.
