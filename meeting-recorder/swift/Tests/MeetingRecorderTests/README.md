# Visual chrome snapshots

Meetings title chrome (and future chrome blocks) use
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).

## Run

```bash
cd meeting-recorder/swift
swift test --filter MeetingsTitleBlock
```

## Re-record goldens

After an intentional visual change, or after a major macOS / SF Symbol bump on CI:

```bash
SNAPSHOT_TESTING_RECORD=1 swift test --filter MeetingsTitleBlock
```

Commit the updated PNGs under `__Snapshots__/`. Do **not** silence diffs with looser precision unless the OS major version forces a rebaseline.

## What we assert

- **midY:** record and filter slots share the same vertical center (±1 pt).
- **snapshot:** fixed dark canvas of `MeetingsTitleBlock` only (not the whole Meetings list).
