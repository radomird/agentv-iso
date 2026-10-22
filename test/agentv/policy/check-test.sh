#!/bin/bash

# Guards the fast gate itself: bin/agentv-check must pass a clean fork and
# fail each kind of change it exists to stop. It builds a throwaway repo with
# a fake upstream tag, so it never touches this checkout. Runs on bash 3.2.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ci_flag=()
[[ ${1:-} == "--ci" ]] && ci_flag=(--ci)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/    /' >&2
  exit 1
}

have() {
  type -P "$1" >/dev/null
}

repo="$SANDBOX/fork"
mkdir -p "$repo"
cd "$repo"
git init -q -b main
git config user.name "AgenTV test"
git config user.email "test@example.invalid"
git remote add origin "https://github.com/example-owner/agentv-os.git"

# Upstream: an MIT licence and a file of Omarchy's that has an em dash of its
# own, which is not ours to change.
printf 'Permission is hereby granted, free of charge, to any person\n' >LICENSE
printf 'upstream text \xe2\x80\x94 not ours\n' >upstream.txt
mkdir -p bin
printf '#!/bin/bash\necho upstream\n' >bin/omarchy-thing
git add -A
git commit -q -m "Upstream release"
git tag v1.0.0

# AgenTV's additions.
mkdir -p .github test/agentv/policy
cp "$ROOT/bin/agentv-check" bin/
cp "$ROOT"/test/agentv/policy/service-* "$ROOT"/test/agentv/policy/upstream-exceptions \
  "$ROOT"/test/agentv/policy/owner-allowed test/agentv/policy/
printf 'v1.0.0\n' >.github/omarchy-base
printf 'example/upstream\n' >.github/omarchy-upstream
printf 'AgenTV. Powered by Omarchy.\n' >.github/README.md
printf '#!/bin/bash\n\necho "hello"\n' >bin/agentv-hello
chmod +x bin/agentv-hello
git add -A
git commit -q -m "Add AgenTV"
clean=$(git rev-parse HEAD)

reset_fork() {
  git reset -q --hard "$clean"
  git clean -qfdx
}

# expect_fail <description> <text the gate must print>
expect_fail() {
  local description="$1" expected="$2" output

  if output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1); then
    fail "$description" "the gate passed, but it should have failed"
  fi
  [[ $output == *"not ok - $expected"* ]] || fail "$description" "$output"
  pass "$description"
  reset_fork
}

# --- A clean fork passes ----------------------------------------------------

output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) || fail "a clean fork passes" "$output"
pass "a clean fork passes"

# --- Each rule catches what it's for ----------------------------------------

printf 'changed\n' >>upstream.txt
expect_fail "an edited Omarchy file fails, even uncommitted" "Omarchy's files are unchanged"

printf 'changed\n' >>upstream.txt
git commit -qam "Edit upstream"
expect_fail "an edited Omarchy file fails once committed" "Omarchy's files are unchanged"

git rm -q bin/omarchy-thing
expect_fail "a deleted Omarchy file fails" "Omarchy's files are unchanged"

git mv upstream.txt renamed.txt
expect_fail "a renamed Omarchy file fails" "Omarchy's files are unchanged"

printf 'upstream.txt\n' >>test/agentv/policy/upstream-exceptions
printf 'allowed\n' >>upstream.txt
output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) || fail "a listed exception may change" "$output"
pass "a listed exception may change"
reset_fork

printf 'a pause \xe2\x80\x94 here\n' >notes.md
expect_fail "an em dash in a new file fails" "no em dashes"

printf 'fine\n' >notes.md
git add notes.md
git commit -q -m "$(printf 'Add notes \xe2\x80\x94 with a dash')"
expect_fail "an em dash in a commit message fails" "no em dashes"

printf 'const home = "https://www.netflix.com/browse";\n' >app.ts
expect_fail "a service host in code fails" "no service automation"

printf 'Never write code for these: see the hosts in the policy.\nwww.disneyplus.com\n' >notes.md
expect_fail "a service host in prose fails too" "no service automation"

printf 'export const selector = "spotify-player";\n' >app.ts
expect_fail "a service name in code fails" "no service automation"

printf 'Spotify is only ever agent-built, on the box.\n' >notes.md
output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) || fail "a service name in prose is allowed" "$output"
pass "a service name in prose is allowed"
reset_fork

printf 'const url = "https://github.com/example-owner/agentv-index";\n' >app.ts
expect_fail "the GitHub owner in code fails" "the GitHub owner"

mkdir -p setup
printf '<h1>Ready \xe2\x9c\x85</h1>\n' >setup/welcome.html
expect_fail "an emoji in UI text fails" "no emoji in UI text"

mkdir -p setup
printf '<p>Connected \xe2\x9c\x93</p>\n' >setup/welcome.html
output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) || fail "a plain check mark is not an emoji" "$output"
pass "a plain check mark is not an emoji"
reset_fork

printf 'Just AgenTV.\n' >.github/README.md
expect_fail "a README without Powered by Omarchy fails" "Omarchy's attribution is present"

if have shellcheck; then
  # shellcheck disable=SC2016 # the broken script is the point
  printf '#!/bin/bash\necho $1\n' >bin/agentv-unquoted
  expect_fail "a shellcheck warning fails" "shell scripts pass shellcheck"

  mkdir -p install/tv
  # shellcheck disable=SC2016 # the broken leaf is the point
  printf 'cd $HOME\n' >install/tv/leaf.sh
  expect_fail "a sourced leaf without a shebang is checked too" "shell scripts pass shellcheck"
else
  printf 'skip - shellcheck cases (shellcheck is not installed)\n'
fi

if have gitleaks; then
  # Built at run time, so this file holds no token for gitleaks to find.
  token="ghp_$(openssl rand -hex 18)"
  printf 'GITHUB_TOKEN=%s\n' "$token" >leak.env
  expect_fail "a token in a file fails" "no secrets"

  printf 'GITHUB_TOKEN=%s\n' "$token" >leak.env
  git add leak.env
  git commit -q -m "Add a token"
  git rm -q leak.env
  git commit -q -m "Remove the token"
  expect_fail "a token removed in a later commit still fails" "no secrets"
else
  printf 'skip - secret cases (gitleaks is not installed)\n'
fi

# --- File names can't run code or hide from the scans -----------------------

# perl's two-argument open runs a name like this as a command.
printf 'a pause \xe2\x80\x94 here\n' >'x|touch PWNED|'
output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) && fail "a file named like a pipe is still scanned" "$output"
[[ ! -e PWNED ]] || fail "a file name can't run a command"
[[ $output == *"not ok - no em dashes"* ]] || fail "a file named like a pipe is still scanned" "$output"
pass "a file name can't run a command, and that file is still scanned"
reset_fork

printf 'a pause \xe2\x80\x94 here\n' >-n
expect_fail "a file whose name starts with a dash is still scanned" "no em dashes"

printf 'a pause \xe2\x80\x94 here\n' >"$(printf 'caf\xc3\xa9 notes.md')"
expect_fail "a file with an unusual name is still scanned" "no em dashes"

printf 'fine\n' >"$(printf 'two\nlines')"
expect_fail "a file name with a newline fails" "file names have no control characters"

# --- A repo of AgenTV's own has no Omarchy base ----------------------------

own="$SANDBOX/own"
mkdir -p "$own/bin" "$own/test/agentv/policy"
cd "$own"
git init -q -b main
git config user.name "AgenTV test"
git config user.email "test@example.invalid"
git remote add origin "https://github.com/example-owner/agentv-pkgs.git"
cp "$repo/bin/agentv-check" bin/
cp "$repo"/test/agentv/policy/* test/agentv/policy/
printf 'Permission is hereby granted, free of charge, to any person\n' >LICENSE
printf 'AgenTV packages. Powered by Omarchy.\n' >README.md
git add -A
git commit -q -m "Start AgenTV's own repo"

output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) || fail "a repo with no Omarchy base passes" "$output"
[[ $output == *"not a fork"* ]] || fail "a repo with no Omarchy base says so" "$output"
pass "a repo with no Omarchy base passes, and says so"

printf 'a pause \xe2\x80\x94 here\n' >>README.md
git commit -qam "Edit the README"
output=$(bin/agentv-check ${ci_flag[@]+"${ci_flag[@]}"} 2>&1) && fail "a repo with no base still gets every scan" "$output"
[[ $output == *"not ok - no em dashes"* ]] || fail "a repo with no base still gets every scan" "$output"
pass "a repo with no base still gets every scan"

printf '\nThe fast gate catches what it should.\n'
