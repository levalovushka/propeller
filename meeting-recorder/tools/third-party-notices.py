#!/usr/bin/env python3
"""Regenerates swift/Resources/ThirdPartyNotices.txt — every license text the .app owes.

    python3 -I meeting-recorder/tools/third-party-notices.py

build.sh turns the file into Credits.rtf, which the standard About panel shows, and
refuses to build when the gigastt or Ollama version in the bundle is not the one this
file was generated for. So bumping either one means running this again. It needs the
network: crate and Go module sources, upstream LICENSE files. NOTICES_CACHE keeps the
downloads between runs (default ~/Library/Caches/propeller-third-party-notices).

What it covers and how each part is found:
  gigastt            LICENSE + NOTICE next to the binary (opus-rs notice is in NOTICE)
  Rust crates        gigastt's Cargo.lock at the binary's version tag, walked from the
                     gigastt crate with dev-only and feature-disabled deps removed; checked
                     against the crate paths the binary itself carries
  ONNX Runtime       statically linked into gigastt; version read from the binary
  GigaAM weights     MIT, from the ONNX export the weights come from
  Ollama             LICENSE at the tag; Go modules from `go version -m` of the binary
  llama.cpp          commit from `llama-server --version`; LICENSE, licenses/, vendor/
  SPM packages       .build/checkouts at the versions in Package.resolved
  Runtime downloads  attribution for the models fetched at first use (not in the bundle)
"""
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
MR = HERE.parent                      # meeting-recorder/
SWIFT = MR / "swift"
OUT = SWIFT / "Resources" / "ThirdPartyNotices.txt"
CACHE = Path(os.environ.get("NOTICES_CACHE",
                            Path.home() / "Library/Caches/propeller-third-party-notices"))

# The app ships only these SPM products; snapshot-testing and its deps are test-only.
SHIPPED_SPM = [("Sparkle", "sparkle"), ("FluidAudio", "fluidaudio"), ("TelemetryDeck SwiftSDK", "swiftsdk")]

# gigastt is built with these gigastt-core features (gigastt/Cargo.toml asks for the first
# four, its default feature adds diarization, CoreML.framework in `otool -L` is coreml).
GIGASTT_CORE_FEATURES = {"net", "async-pool", "file-decode", "quantize", "diarization", "coreml"}

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|COPYRIGHT|UNLICENSE)", re.I)
RULE = "=" * 78


def die(msg):
    sys.exit(f"third-party-notices: {msg}")


def find_tool(rel):
    """Same lookup order as build.sh: this checkout, then the main one (worktrees)."""
    for base in (MR.parent, Path.home() / "Desktop/Propeller"):
        p = base / rel
        if p.exists():
            return p
    die(f"{rel} not found")


def fetch(url, dest):
    dest = Path(dest)
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(url, headers={"User-Agent": "propeller-third-party-notices"})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
        dest.write_bytes(data)
    return dest


def text(path):
    return Path(path).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").strip("\n")


def run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kw).stdout


def license_files(directory):
    return sorted(p for p in Path(directory).iterdir() if p.is_file() and LICENSE_FILE.match(p.name))


def section(out, title, body_lines):
    out += ["", RULE, title, RULE, ""] + body_lines


def grouped_texts(entries):
    """entries: [(label, [texts])] -> lines; identical texts printed once with who they cover."""
    by_text = {}
    for label, texts in entries:
        for t in texts:
            by_text.setdefault(t, []).append(label)
    lines = []
    for t, labels in sorted(by_text.items(), key=lambda kv: kv[1][0].lower()):
        lines += ["-" * 78, "Applies to: " + ", ".join(sorted(set(labels))), "-" * 78, "", t, ""]
    return lines


# --- gigastt and what is inside it ------------------------------------------------------

def rust_crates(gigastt_version, binary_strings):
    tag = f"v{gigastt_version}"
    base = f"https://raw.githubusercontent.com/ekhodzitsky/gigastt/{tag}"
    lock = tomllib.loads(text(fetch(f"{base}/Cargo.lock", CACHE / f"gigastt-{tag}/Cargo.lock")))
    manifests = {c: tomllib.loads(text(fetch(f"{base}/crates/{c}/Cargo.toml",
                                             CACHE / f"gigastt-{tag}/{c}.Cargo.toml")))
                 for c in ("gigastt", "gigastt-core")}

    # Edges from the two workspace crates that do not reach the binary.
    def deps_of(m):
        names = set(m.get("dependencies", {}))
        for t in m.get("target", {}).values():
            names |= set(t.get("dependencies", {}))
        return names
    cut = {c: set(m.get("dev-dependencies", {})) - deps_of(m) for c, m in manifests.items()}
    core = manifests["gigastt-core"]
    enabled = set()
    for f in GIGASTT_CORE_FEATURES:
        enabled |= {d[4:] for d in core["features"].get(f, []) if d.startswith("dep:")}
    optional = {n for n, spec in core.get("dependencies", {}).items()
                if isinstance(spec, dict) and spec.get("optional")}
    for t in core.get("target", {}).values():
        optional |= {n for n, spec in t.get("dependencies", {}).items()
                     if isinstance(spec, dict) and spec.get("optional")}
    cut["gigastt-core"] |= optional - enabled

    pkgs = {(p["name"], p["version"]): p for p in lock["package"]}
    versions = {}
    for n, v in pkgs:
        versions.setdefault(n, []).append(v)
    not_macos = re.compile(r"^(windows|winapi|wasm|web-sys|js-sys|android|ndk|jni|libredox|redox|"
                           r"hermit|wasi|r-efi|linux-raw-sys|rustix)")
    seen, stack = set(), [("gigastt", gigastt_version)]
    while stack:
        key = stack.pop()
        if key in seen:
            continue
        seen.add(key)
        for d in pkgs[key].get("dependencies", []):
            n, _, v = d.partition(" ")
            v = v or versions[n][0]
            if n in cut.get(key[0], ()) or not_macos.match(n):
                continue
            stack.append((n, v))
    crates = sorted((n, v) for n, v in seen if pkgs[(n, v)].get("source", "").startswith("registry"))

    # The binary names the source path of every crate that can panic; each must be in the set.
    names = {(n, v.split("+")[0]) for n, v in crates}
    in_binary = set(re.findall(r"registry/src/[^/]+/([A-Za-z0-9_-]+?)-(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)/",
                               binary_strings))
    missing = in_binary - names
    if missing:
        die(f"crates in the gigastt binary but not in Cargo.lock {tag}: {sorted(missing)}")

    entries, listing = [], []
    for n, v in crates:
        d = CACHE / "crates" / f"{n}-{v}"
        if not d.exists():
            archive = fetch(f"https://static.crates.io/crates/{n}/{n}-{v.replace('+', '%2B')}.crate",
                            CACHE / "crates" / f"{n}-{v}.crate")
            d.mkdir(parents=True)
            with tarfile.open(archive) as tar:
                for m in tar.getmembers():
                    parts = m.name.split("/")
                    if m.isfile() and len(parts) == 2 and (parts[1] == "Cargo.toml" or LICENSE_FILE.match(parts[1])):
                        (d / parts[1]).write_bytes(tar.extractfile(m).read())
            archive.unlink()
        spdx = tomllib.loads(text(d / "Cargo.toml")).get("package", {}).get("license", "see license file")
        files = license_files(d)
        listing.append(f"  {n} {v} — {spdx}" + ("" if files else "  (no license file in the crate package)"))
        entries.append((f"{n} {v}", [text(f) for f in files]))
    return crates, listing, entries


def ort_version(binary_strings):
    found = sorted(set(re.findall(r"(?m)^1\.\d\d\.\d+$", binary_strings)))
    if len(found) != 1:
        die(f"cannot tell the ONNX Runtime version inside gigastt (candidates: {found})")
    return found[0]


# --- Ollama and what is inside it ------------------------------------------------------

def go_modules(ollama_bin):
    info = run("go", "version", "-m", str(ollama_bin))
    go = re.search(r":\s*(go[\d.]+)", info).group(1)
    mods = re.findall(r"(?m)^\tdep\t(\S+)\t(\S+)", info)
    env = dict(os.environ, GOMODCACHE=str(CACHE / "gomod"), GOFLAGS="-modcacherw",
               GO111MODULE="on", GOTOOLCHAIN="local")
    (CACHE / "gomod").mkdir(parents=True, exist_ok=True)
    listing, entries = [], []
    for m, v in mods:
        meta = json.loads(run("go", "mod", "download", "-json", f"{m}@{v}", env=env, cwd=CACHE))
        files = license_files(meta["Dir"])
        listing.append(f"  {m} {v}" + ("" if files else "  (no license file in the module)"))
        entries.append((f"{m} {v}", [text(f) for f in files]))
    return go, listing, entries


def llama_cpp(llama_server):
    out = subprocess.run([str(llama_server), "--version"], capture_output=True, text=True)
    short = re.search(r"\(([0-9a-f]{7,})\)", out.stdout + out.stderr)
    if not short:
        die("llama-server --version did not name a commit")
    sha = json.loads(fetch(f"https://api.github.com/repos/ggml-org/llama.cpp/commits/{short.group(1)}",
                           CACHE / f"llama.cpp-{short.group(1)}.json").read_text())["sha"]
    tree = json.loads(fetch(f"https://api.github.com/repos/ggml-org/llama.cpp/git/trees/{sha}?recursive=1",
                            CACHE / f"llama.cpp-{sha}-tree.json").read_text())
    paths = [t["path"] for t in tree["tree"] if t["type"] == "blob"]
    wanted = ["LICENSE"] + [p for p in paths if p.startswith("licenses/")] \
        + [p for p in paths if p.startswith("vendor/") and LICENSE_FILE.match(p.rsplit("/", 1)[1])]
    texts = [(p, text(fetch(f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{sha}/{p}",
                            CACHE / f"llama.cpp-{sha}" / p))) for p in wanted]
    vendored = sorted({p.split("/")[1] for p in paths if p.startswith("vendor/")})
    return short.group(1), sha, texts, vendored


# --- SPM ----------------------------------------------------------------------------------

def spm_packages():
    resolved = json.loads((SWIFT / "Package.resolved").read_text())
    pins = {p["identity"]: p["state"].get("version") for p in resolved["pins"]}
    out = []
    for title, identity in SHIPPED_SPM:
        d = next((c for c in (SWIFT / ".build/checkouts").iterdir() if c.name.lower() == identity), None) \
            if (SWIFT / ".build/checkouts").exists() else None
        if d is None:
            die(f"{identity} checkout missing — run `swift package resolve` in {SWIFT}")
        files = license_files(d)
        third = d / "ThirdPartyLicenses"
        if third.is_dir():
            files += sorted(p for p in third.iterdir() if p.is_file())
        out.append((title, pins[identity], [(f.relative_to(d), text(f)) for f in files]))
    return out


# --- assemble ----------------------------------------------------------------------------

def main():
    gigastt = find_tool("tools/gigastt/gigastt")
    gigastt_version = run(str(gigastt), "--version").split()[-1]
    gigastt_strings = run("strings", str(gigastt))
    build_sh = (SWIFT / "build.sh").read_text()
    ollama_tag = re.search(r'^OLLAMA_TAG="([^"]+)"', build_sh, re.M).group(1)
    ollama_tgz = Path(os.environ["OLLAMA_TGZ"]) if os.environ.get("OLLAMA_TGZ") else \
        find_tool(f"tools/ollama/ollama-darwin-{ollama_tag}-slim.tgz")

    crates, crate_listing, crate_entries = rust_crates(gigastt_version, gigastt_strings)
    ort = ort_version(gigastt_strings)
    ort_base = f"https://raw.githubusercontent.com/microsoft/onnxruntime/v{ort}"
    with tempfile.TemporaryDirectory() as tmp:
        run("tar", "-xzf", str(ollama_tgz), "-C", tmp)
        go, go_listing, go_entries = go_modules(Path(tmp) / "ollama")
        llama_short, llama_sha, llama_texts, vendored = llama_cpp(Path(tmp) / "llama-server")
        has_mlx = any(p.name.startswith("mlx_metal") for p in Path(tmp).iterdir())
    spm = spm_packages()

    out = [
        "Propeller — third-party notices",
        "",
        # One line each: the About panel wraps text itself, a hard break mid-sentence shows.
        "Propeller includes the software and model weights listed below. Their licenses "
        "require the notices that follow to accompany every copy of the application.",
        "",
        "Generated by meeting-recorder/tools/third-party-notices.py for:",
        f"  gigastt {gigastt_version} (ONNX Runtime {ort}, {len(crates)} Rust crates)",
        f"  Ollama {ollama_tag} ({go}, {len(go_listing)} Go modules, llama.cpp {llama_short})",
        "  " + ", ".join(f"{t} {v}" for t, v, _ in spm),
        "",
        "Contents",
        "  1. gigastt — speech recognition engine (Contents/MacOS/gigastt)",
        "  2. ONNX Runtime — linked into gigastt",
        "  3. Rust crates — linked into gigastt",
        "  4. GigaAM v3 — speech recognition weights (Contents/Resources/gigastt-models)",
        "  5. Ollama — summary engine (Contents/Resources/ollama-darwin.tgz)",
        "  6. Go and Go modules — linked into Ollama",
        "  7. llama.cpp — inference server shipped with Ollama",
        "  8. Swift packages — linked into Propeller",
        "  9. Models downloaded at first use (not part of the application package)",
    ]

    gdir = gigastt.parent
    section(out, f"1. gigastt {gigastt_version} — https://github.com/ekhodzitsky/gigastt",
            ["--- LICENSE ---", "", text(gdir / "LICENSE"), "", "--- NOTICE ---", "", text(gdir / "NOTICE")])

    section(out, f"2. ONNX Runtime {ort} — https://github.com/microsoft/onnxruntime",
            ["--- LICENSE ---", "", text(fetch(f"{ort_base}/LICENSE", CACHE / f"onnxruntime-{ort}/LICENSE")),
             "", "--- ThirdPartyNotices.txt ---", "",
             text(fetch(f"{ort_base}/ThirdPartyNotices.txt", CACHE / f"onnxruntime-{ort}/ThirdPartyNotices.txt"))])

    section(out, f"3. Rust crates linked into gigastt {gigastt_version}",
            ["From Cargo.lock of gigastt v" + gigastt_version + ". Where a crate offers a choice of",
             "licenses, all of its license files are reproduced.", ""] + crate_listing + [""]
            + grouped_texts(crate_entries))

    section(out, "4. GigaAM v3 weights — https://github.com/salute-developers/GigaAM",
            ["ONNX export: https://huggingface.co/istupakov/gigaam-v3-onnx", "",
             text(fetch("https://huggingface.co/istupakov/gigaam-v3-onnx/raw/main/LICENSE.txt",
                        CACHE / "gigaam-v3-onnx/LICENSE.txt"))])

    ollama_lines = [text(fetch(f"https://raw.githubusercontent.com/ollama/ollama/{ollama_tag}/LICENSE",
                               CACHE / f"ollama-{ollama_tag}/LICENSE"))]
    if has_mlx:
        ollama_lines += ["", "--- MLX (mlx_metal_*), https://github.com/ml-explore/mlx ---", "",
                         text(fetch("https://raw.githubusercontent.com/ml-explore/mlx/main/LICENSE",
                                    CACHE / "mlx/LICENSE"))]
    section(out, f"5. Ollama {ollama_tag} — https://github.com/ollama/ollama", ollama_lines)

    # From the tag the binary was built with: Homebrew's Go ships without its LICENSE.
    go_license = fetch(f"https://raw.githubusercontent.com/golang/go/{go}/LICENSE", CACHE / f"{go}/LICENSE")
    section(out, f"6. Go ({go}) and Go modules linked into Ollama {ollama_tag}",
            ["--- Go, https://go.dev ---", "", text(go_license), "",
             "Modules:"] + go_listing + [""] + grouped_texts(go_entries))

    llama_lines = [f"Commit {llama_sha}", ""]
    for p, t in llama_texts:
        llama_lines += [f"--- {p} ---", "", t, ""]
    llama_lines += [
        "Vendored without a separate license file (" + ", ".join(vendored) + "): stb_image,",
        "miniaudio and sheredom/subprocess.h are dedicated to the public domain",
        "(Unlicense) with an MIT alternative; nlohmann/json is licensed under",
        "licenses/LICENSE-jsonhpp above."]
    section(out, f"7. llama.cpp {llama_short} — https://github.com/ggml-org/llama.cpp", llama_lines)

    spm_lines = []
    for title, version, files in spm:
        spm_lines += ["-" * 78, f"{title} {version}", "-" * 78, ""]
        for rel, t in files:
            spm_lines += [f"--- {rel} ---", "", t, ""]
    section(out, "8. Swift packages linked into Propeller", spm_lines)

    section(out, "9. Models downloaded at first use (not part of the application package)", [
        "Speaker diarization — FluidInference/speaker-diarization-coreml",
        "https://huggingface.co/FluidInference/speaker-diarization-coreml",
        "Modified Core ML conversions by Fluid Inference of pyannote speaker-diarization-",
        "community-1 (pyannote), WeSpeaker embeddings and BUT Speech@FIT PLDA parameters,",
        "licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/",
        "The repository's attribution notice follows.", "",
        text(fetch("https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/NOTICE.md",
                   CACHE / "speaker-diarization-coreml/NOTICE.md")), "",
        "Summary model — Qwen3.5-4B by the Qwen team, Alibaba Cloud, Apache License 2.0:",
        "https://huggingface.co/Qwen/Qwen3.5-4B — downloaded by Ollama from its library.",
    ])

    OUT.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
    print(f"{OUT} — {OUT.stat().st_size // 1024} KB, {len(crates)} crates, {len(go_listing)} Go modules")


if __name__ == "__main__":
    main()
