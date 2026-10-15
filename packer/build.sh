#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"

if ! git -C "${repo_root}" diff --quiet || ! git -C "${repo_root}" diff --cached --quiet; then
  echo "Refusing to build from a dirty tracked worktree; commit or stash changes first." >&2
  exit 1
fi

export PKR_VAR_packer_repo_git_sha="$(git -C "${repo_root}" rev-parse HEAD)"
export PKR_VAR_build_date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cd "${script_dir}"
exec packer build -var-file=variables.auto.pkrvars.hcl .
