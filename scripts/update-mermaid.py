"""Vendor mermaid.js and list what is inside it.

    python3 -I scripts/update-mermaid.py 12.3.0

Downloads the mermaid package from npm, copies dist/mermaid.min.js to Sources/viw/Mermaid/ and
writes Sources/viw/Mermaid/THIRD_PARTY_LICENSES.txt: every npm package the source map of that file
names, at the version that was bundled, with the license text from the package itself. Needs npm
(only `npm pack`, which downloads tarballs and runs none of their scripts) and the network.
"""
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

DEST = Path(__file__).resolve().parent.parent / "Sources/viw/Mermaid"

# Bundled inside @mermaid-js/parser before mermaid is built, so mermaid's source map does not name
# them: langium and what it declares as dependencies (chevrotain is in the map already). Ranges as
# declared; the license of a package does not change within one.
PARSER = ["@mermaid-js/parser@{parser}", "langium@{langium}", "chevrotain-allstar@~0.5.0", "@chevrotain/types@~13.2.0",
          "vscode-languageserver@~10.1.0", "vscode-languageserver-protocol@~3.18.2", "vscode-languageserver-types@~3.18.0",
          "vscode-languageserver-textdocument@~1.0.13", "vscode-jsonrpc@*", "vscode-uri@~3.1.0"]

# Packages offered under a choice of licenses: the one viw takes.
CHOICE = {
    "dompurify": "Apache-2.0 (offered as MPL-2.0 OR Apache-2.0)",
    "elkjs": "EPL-2.0 (offered as EPL-2.0 OR GPL-3.0-or-later); unmodified, source: https://github.com/kieler/elkjs",
}

# Packages whose package.json states no license: read from the LICENSE file in the package.
STATED_IN_FILE = {"khroma": "MIT"}


MIT = """MIT License

Copyright (c) {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def pack(spec: str, into: Path) -> Path:
    """`npm pack spec` into a new directory; the extracted package/ directory."""
    d = Path(tempfile.mkdtemp(dir=into))
    subprocess.run(["npm", "pack", spec, "--pack-destination", str(d), "--silent"], check=True, stdout=subprocess.DEVNULL)
    (tgz,) = d.glob("*.tgz")
    with tarfile.open(tgz) as t:
        t.extractall(d, filter="data")
    (root,) = [p for p in d.iterdir() if p.is_dir()]
    return root


def bundled(source_map: Path) -> set[str]:
    """name@version of every npm package the source map takes code from."""
    found = set()
    for source in json.loads(source_map.read_text())["sources"]:
        # .../node_modules/.pnpm/<name>@<version>[_peers]/node_modules/<name>/...
        m = re.search(r"\.pnpm/((?:@[^/+@]+\+)?[^/@]+)@([^/_]+)[^/]*/node_modules/((?:@[^/]+/)?[^/]+)/", source)
        if m and m.group(1).replace("+", "/") == m.group(3):
            found.add(f"{m.group(3)}@{m.group(2)}")
        elif "node_modules/" in source:
            sys.exit(f"cannot tell the package of {source}")
    return found


def license_text(root: Path) -> str:
    files = sorted(p for p in root.iterdir() if p.is_file() and re.match(r"(?i)(licen[sc]e|copying|notice)", p.name))
    return "\n\n".join(p.read_text(errors="replace").strip() for p in files)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    version = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        mermaid = pack(f"mermaid@{version}", tmp)
        shutil.copyfile(mermaid / "dist/mermaid.min.js", DEST / "mermaid.min.js")

        specs = bundled(mermaid / "dist/mermaid.min.js.map")
        # The parser is built from the same repository; the version mermaid asks for is the one bundled.
        wanted = json.loads((mermaid / "package.json").read_text())["dependencies"]["@mermaid-js/parser"].lstrip("^~")
        parser = json.loads((pack(f"@mermaid-js/parser@{wanted}", tmp) / "package.json").read_text())
        langium = {**parser.get("dependencies", {}), **parser.get("devDependencies", {})}["langium"]
        specs |= {s.format(parser=parser["version"], langium=langium) for s in PARSER}

        entries = [("mermaid", version, "MIT", license_text(mermaid))]
        for spec in sorted(specs):
            root = pack(spec, tmp)
            meta = json.loads((root / "package.json").read_text())
            name = meta["name"]
            stated = meta.get("license") or STATED_IN_FILE.get(name)
            text = license_text(root)
            if stated == "MIT" and not text:
                # The package ships no license file: the MIT text with the author package.json names.
                author = meta.get("author", "")
                author = author.get("name", "") if isinstance(author, dict) else author
                text = "(no license file in the package)\n\n" + MIT.format(holder=author or f"the {name} authors")
            if not stated or not text:
                sys.exit(f"{spec}: no license ({stated!r}) or no license file")
            entries.append((name, meta["version"], CHOICE.get(name, stated), text))

    out = ["Third-party software in viw's Mermaid support",
           "",
           f"Sources/viw/Mermaid/mermaid.min.js is the unmodified dist/mermaid.min.js of mermaid {version}",
           "(https://github.com/mermaid-js/mermaid). It bundles the packages below; each is listed with the",
           "license it is used under and the license text shipped in the package. Written by",
           "scripts/update-mermaid.py. langium and the vscode-* packages come in through @mermaid-js/parser,",
           "which does not record their exact versions: the newest within the ranges it declares are listed.",
           ""]
    out += [f"  {name} {ver} — {lic}" for name, ver, lic, _ in entries]
    for name, ver, lic, text in entries:
        out += ["", "=" * 100, f"{name} {ver} — {lic}", "=" * 100, "", text]
    (DEST / "THIRD_PARTY_LICENSES.txt").write_text("\n".join(out) + "\n")
    print(f"mermaid {version}: {len(entries)} packages")


main()
