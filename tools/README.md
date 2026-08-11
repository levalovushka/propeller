# tools/

Expected layout (not committed):

```
tools/gigastt/
  gigastt          # binary from ekhodzitsky/gigastt
  models-e2e/      # GigaAM e2e_rnnt (~225 MB+)
tools/ollama/
  ollama-darwin-<tag>.tgz        # official release, fetched on demand
  ollama-darwin-<tag>-slim.tgz   # what actually ships — built by meeting-recorder/tools/slim-ollama.sh
```

`meeting-recorder/swift/build.sh` bundles `tools/gigastt/gigastt` into the `.app`, and
prefers the slim engine archive (34 MB instead of 139 — the MLX runtime and the Intel CPU
backends are removed, neither being reachable on an arm64-only app). It refuses to build
if the archive lacks `ollama` or `llama-server`, and it checks that **before** deleting the
installed bundle.

Both directories are generated, not committed.
