# tools/

Expected layout (not committed):

```
tools/gigastt/
  gigastt          # binary from ekhodzitsky/gigastt
  models-e2e/      # GigaAM e2e_rnnt (~225 MB+)
```

`meeting-recorder/swift/build.sh` bundles `tools/gigastt/gigastt` into the `.app`.
