#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/manikv12/OpenAssist.wiki.git"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
SOURCE_DIR="${ROOT_DIR}/Wiki"

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "Wiki source directory not found: ${SOURCE_DIR}" >&2
  exit 1
fi

if ! git ls-remote "${REPO_URL}" >/dev/null 2>&1; then
  cat <<'MSG'
Wiki repository is not initialized yet.

One-time setup required:
1. Open https://github.com/manikv12/OpenAssist/wiki
2. Click "Create the first page"
3. Save any placeholder content

Then rerun: Scripts/publish-wiki.sh
MSG
  exit 2
fi

workdir="$(mktemp -d /tmp/openassist-wiki-sync-XXXXXX)"
cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

if command -v gh >/dev/null 2>&1; then
  gh repo clone manikv12/OpenAssist.wiki "${workdir}" -- --depth 1 >/dev/null
else
  git clone --depth 1 "${REPO_URL}" "${workdir}" >/dev/null
fi

cp -f "${SOURCE_DIR}"/*.md "${workdir}/"

cd "${workdir}"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "Wiki is already up to date."
  exit 0
fi

git add *.md
git -c user.name="manikv12" -c user.email="manik@example.com" commit -m "Update wiki content" >/dev/null
git push origin HEAD:master >/dev/null

echo "Wiki published successfully: https://github.com/manikv12/OpenAssist/wiki"
