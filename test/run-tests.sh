#!/usr/bin/env bash
# Regression suite for omarchy-time-machine.
#
# Runs entirely against a throwaway restic repository in a temporary
# directory, with XDG_CONFIG_HOME and XDG_STATE_HOME redirected there, so it
# can never touch a real configuration or a real backup.
#
# Beyond "does it work", this suite pins down the properties that are easy to
# break and expensive to discover in production: that status costs no secret,
# that a planted symlink cannot redirect a write, that input coming back from
# the widget is refused rather than repaired, and that a --json command emits
# nothing but JSON on stdout.
#
#   test/run-tests.sh

set -uo pipefail

CLI="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bin/omarchy-time-machine"
WORK="$(mktemp -d)"
# No desktop notifications from a test run. Without this the suite fires real
# sticky notifications at whoever happens to be logged in, and they have to
# dismiss each one by hand.
export OMARCHY_TIME_MACHINE_QUIET=1
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"

PASSED=0
FAILED=0
SKIPPED=0

# Most of this suite drives a real restic repository. Without restic those
# tests cannot run, and reporting them as failures is worse than useless: a
# machine with no restic printed 34 red lines that said nothing about the
# code, which buries the handful of real results and makes a green run
# indistinguishable from a missing dependency. Groups that need it are marked,
# and their checks are skipped by name instead.
HAVE_RESTIC=1
command -v restic >/dev/null 2>&1 || HAVE_RESTIC=0
GROUP_NEEDS_RESTIC=0

cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

ok()   { PASSED=$((PASSED + 1)); printf '  \033[32mpass\033[0m  %s\n' "$1"; }
no()   { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  \033[33mskip\033[0m  %s\n' "$1"; }
check(){
  if [ "$GROUP_NEEDS_RESTIC" = "1" ] && [ "$HAVE_RESTIC" = "0" ]; then skip "$2"; return; fi
  if [ "$1" = "0" ]; then ok "$2"; else no "$2"; fi
}
group(){ GROUP_NEEDS_RESTIC=0; printf '\n\033[1m%s\033[0m\n' "$1"; }
# Same heading, but every check under it is skipped when restic is missing.
group_restic(){ GROUP_NEEDS_RESTIC=1; printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ "$HAVE_RESTIC" = "0" ]; then
  printf '\033[33mrestic is not installed.\033[0m Everything that needs a repository is\n'
  printf 'skipped below, so the CLI prints its own "restic is not installed" between\n'
  printf 'the results. Install restic to run the whole suite.\n'
fi

# --- fixture ---------------------------------------------------------------

mkdir -p "$XDG_CONFIG_HOME/omarchy-time-machine" "$WORK/repo" "$WORK/src/docs" "$WORK/src/pics"
echo "hello" > "$WORK/src/docs/note.txt"
echo "report" > "$WORK/src/docs/report.md"
head -c 200000 /dev/urandom > "$WORK/src/pics/photo.bin"
echo "should not be backed up" > "$WORK/src/.env"
echo ".env" > "$WORK/excludes.txt"

cat > "$XDG_CONFIG_HOME/omarchy-time-machine/config.json" <<JSON
{
  "version": 1,
  "source": "$WORK/src",
  "exclude_file": "$WORK/excludes.txt",
  "retention": { "daily": 7, "weekly": 4, "monthly": 12, "yearly": 3 },
  "destinations": [
    { "name": "test", "repository": "$WORK/repo", "schedule": "*-*-* 03:00:00" }
  ]
}
JSON

# --- before there is a key -------------------------------------------------

group_restic "Without a key"

$CLI status --json | jq -e '.configured == true' >/dev/null 2>&1
check $? "status works with no key and no network"

# Output is captured first: under `set -o pipefail` the status of
# `cmd | grep` is the command's, not grep's, and every one of these commands
# exits non-zero on purpose.
OUT="$($CLI backup --dest test 2>&1)"
grep -q "key set --dest test" <<<"$OUT"
check $? "a missing key names the command that fixes it"

# --- setup -----------------------------------------------------------------

group_restic "Setup"

printf 'test-password\n' | $CLI key set --dest test >/dev/null 2>&1
check $? "key set"

[ "$(stat -c %a "$XDG_CONFIG_HOME/omarchy-time-machine/test.key")" = "600" ]
check $? "the key file is 600"

[ "$(stat -c %a "$XDG_CONFIG_HOME/omarchy-time-machine")" = "700" ]
check $? "the config directory is 700"

$CLI init --dest test >/dev/null 2>&1
check $? "init creates the repository"

# More than one entry in a destination's secrets file must be exported one at
# a time. The defensive empty-array expansion used here previously collapsed
# the associative array values into one invalid variable name under Bash.
SECRETS_FILE="$XDG_CONFIG_HOME/omarchy-time-machine/test.env"
printf 'REPO_ROOT=%s\nREPO_NAME=repo\n' "$WORK" > "$SECRETS_FILE"
cp "$XDG_CONFIG_HOME/omarchy-time-machine/config.json" "$WORK/config.before-secrets"
jq --arg s "$SECRETS_FILE" '
  .destinations[0].repository = "${REPO_ROOT}/${REPO_NAME}"
  | .destinations[0].secrets_file = $s' \
  "$XDG_CONFIG_HOME/omarchy-time-machine/config.json" > "$WORK/config.with-secrets"
mv "$WORK/config.with-secrets" "$XDG_CONFIG_HOME/omarchy-time-machine/config.json"

$CLI snapshots --dest test --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "multiple secrets-file entries are exported individually"

cp "$WORK/config.before-secrets" "$XDG_CONFIG_HOME/omarchy-time-machine/config.json"

# --- backup ----------------------------------------------------------------

group_restic "Backup"

$CLI backup --dest test >/dev/null 2>&1
check $? "backup exits 0"

STATUS="$XDG_STATE_HOME/omarchy-time-machine/status.json"
jq -e '.destinations.test.last_run.result == "ok"' "$STATUS" >/dev/null 2>&1
check $? "status.json records the result"

jq -e '.destinations.test.last_run.duration_seconds >= 0' "$STATUS" >/dev/null 2>&1
check $? "duration is computed (jq cannot parse date -Iseconds, so epochs are stored too)"

jq -e '.destinations.test.snapshot_count >= 1 and .destinations.test.repo_size_bytes > 0' "$STATUS" >/dev/null 2>&1
check $? "snapshot count and repository size are recorded"

[ "$($CLI snapshots --dest test --json | jq -r '.snapshots[0].summary.total_files_processed')" = "3" ]
check $? "the exclude file is honoured (.env stayed out)"

# --- unreadable source files -----------------------------------------------
#
# restic exits 3 when it could not read something, and still writes a snapshot
# -- one with a hole where that file was. Treating that as success is what lets
# a backup rot in silence: the last snapshot that still held the file ages out
# of the retention policy, prune reclaims its data, and nothing ever went red.

group_restic "Unreadable source files"

GOOD_SUCCESS="$(jq -r '.destinations.test.last_success_at' "$STATUS")"
LOGS="$XDG_STATE_HOME/omarchy-time-machine/logs/test"

chmod 000 "$WORK/src/docs/report.md"
$CLI backup --dest test >/dev/null 2>&1
[ $? -eq 1 ]
check $? "an unreadable file fails the run, and reports it as a plain failure"

# restic's own 3 must not reach systemd. A unit is a copy in the user's home
# that no plugin update can rewrite, so the moment the exit code needs
# interpreting there, the interpretation is stranded in a file this project
# cannot revise. Exit 1 needs no interpreting, which is what lets a stale unit
# carrying SuccessExitStatus=3 still do the right thing.
$CLI backup --dest test >/dev/null 2>&1
[ $? -ne 3 ]
check $? "and restic's exit 3 never leaks out of the CLI"

jq -e '.destinations.test.last_run.result == "failed"' "$STATUS" >/dev/null 2>&1
check $? "and that counts as a failure, not as a success with a footnote"

jq -e --arg p "$WORK/src/docs/report.md" \
  '.destinations.test.last_run.error | test($p)' "$STATUS" >/dev/null 2>&1
check $? "the reason names the file that could not be read"

[ "$(jq -r '.destinations.test.last_success_at' "$STATUS")" = "$GOOD_SUCCESS" ]
check $? "last_success_at still points at the last run that read everything"

LAST_LOG="$(find "$LOGS" -name '*.log' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
grep -q "Removing old snapshots" "$LAST_LOG"
[ $? -ne 0 ]
check $? "and nothing was pruned, so the older snapshots still hold the file"

grep -q "message_type" "$LAST_LOG"
[ $? -ne 0 ]
check $? "restic's stderr reaches the log as prose, not as raw JSON"

chmod 644 "$WORK/src/docs/report.md"
$CLI backup --dest test >/dev/null 2>&1
check $? "a clean run afterwards succeeds again"

LAST_LOG="$(find "$LOGS" -name '*.log' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
grep -q "Removing old snapshots" "$LAST_LOG"
check $? "and prune resumes, clearing the backlog the failures left behind"

# --- reading the repository ------------------------------------------------

group_restic "Reading"

SNAP="$($CLI snapshots --dest test --json | jq -r '.snapshots[0].id')"

[ "$($CLI ls --dest test --snapshot "$SNAP" --path "$WORK/src" --json | jq -r '[.entries[].name] | join(",")')" = "docs,pics" ]
check $? "ls returns direct children only, directories first"

$CLI restore --dest test --snapshot "$SNAP" --path "$WORK/src/docs/report.md" --target "$WORK/restored" >/dev/null 2>&1
[ "$(cat "$WORK/restored$WORK/src/docs/report.md" 2>/dev/null)" = "report" ]
check $? "restore writes the file into the target directory"

# --- large listings --------------------------------------------------------
#
# restic decides how much output a listing produces, and until it is capped at
# the pipe the whole thing is read into a shell variable and then slurped a
# second time by jq. A directory of 60k children measured 25 MiB of output and
# 215 MiB of peak RSS to draw 500 rows. Cutting the stream at a line boundary
# is what keeps that bounded -- and what could just as easily hand jq a half
# object, which is the part worth pinning down.

group_restic "Large listings"

mkdir -p "$WORK/src/many"
(cd "$WORK/src/many" && seq 1 6000 | xargs -P8 -n1000 touch)
$CLI backup --dest test >/dev/null 2>&1
BIGSNAP="$($CLI snapshots --dest test --json | jq -r '.snapshots[0].id')"
BIGLS="$($CLI ls --dest test --snapshot "$BIGSNAP" --path "$WORK/src/many" --json)"

jq -e '.ok == true' <<<"$BIGLS" >/dev/null 2>&1
check $? "a listing cut at the line cap is still valid JSON, not a half object"

jq -e '.entries | length == 500' <<<"$BIGLS" >/dev/null 2>&1
check $? "and it is capped at LS_ENTRY_CAP rows"

jq -e '.truncated == true' <<<"$BIGLS" >/dev/null 2>&1
check $? "and says so, rather than presenting a partial listing as complete"

# --- untrusted text in shell components ------------------------------------
#
# Filenames come out of the backup, and a Text with no textFormat falls back to
# Qt's AutoText, which renders anything tag-shaped as rich text and fetches
# what it points at. ConfirmDialog is a shell component that sets no
# textFormat, so the escaping has to happen on this side. Asserted against the
# source because there is no QML runtime in this suite to render it.

group "Untrusted text in shell components"

BROWSER="$(dirname "$CLI")/../RestoreBrowser.qml"

grep -q 'TimeMachineStore\.plain(root\.restoreTargetName)' "$BROWSER"
check $? "a filename reaches ConfirmDialog through plain()"

grep -qE '\+ *root\.restoreTargetName|root\.restoreTargetName *\+' "$BROWSER"
[ $? -ne 0 ]
check $? "and nowhere is it concatenated into a string raw"

grep -q 'replace(/\[<>\]/g' "$(dirname "$CLI")/../TimeMachineStore.qml"
check $? "and plain() is what strips the characters that make Qt see markup"

# --- input validation ------------------------------------------------------
#
# Snapshot ids and paths travel from the widget back into restic. They are
# treated as input: refused on the wrong shape rather than repaired.

group_restic "Input validation"

$CLI ls --dest test --snapshot "../../etc/passwd" --path /tmp --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "a path-traversal snapshot id is refused"

$CLI ls --dest test --snapshot "$SNAP" --path "relative/path" --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "a relative path is refused"

$CLI restore --dest test --snapshot "zzz" --path /tmp --json | jq -e '.ok == false' >/dev/null 2>&1
check $? "restore refuses an invalid id (die inside \$( ) would only kill a subshell)"

# --- stdout discipline -----------------------------------------------------
#
# The widget parses stdout. A stray progress line there is indistinguishable
# from a crashed script, which is exactly what a pre_command once caused.

group_restic "stdout discipline"

CONFIG="$XDG_CONFIG_HOME/omarchy-time-machine/config.json"
cp "$CONFIG" "$WORK/config.bak"
jq '.destinations[0].pre_command = "echo noise from pre_command"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

$CLI snapshots --dest test --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
check $? "a pre_command does not pollute JSON on stdout"

cp "$WORK/config.bak" "$CONFIG"

# --- file safety -----------------------------------------------------------

group_restic "File safety"

echo "MUST SURVIVE" > "$WORK/victim.txt"
rm -f "$STATUS"
ln -s "$WORK/victim.txt" "$STATUS"
$CLI backup --dest test >/dev/null 2>&1
[ "$(cat "$WORK/victim.txt")" = "MUST SURVIVE" ]
check $? "a symlink planted on status.json cannot redirect the write"

[ ! -L "$STATUS" ]
check $? "and the planted symlink is removed"

# Dotfiles managed with stow are symlinks by design. Strictness that refuses
# them would break an ordinary setup, so paths the user names are followed.
mkdir -p "$WORK/dotfiles"
cp "$CONFIG" "$WORK/dotfiles/config.json"
rm "$CONFIG"
ln -s "$WORK/dotfiles/config.json" "$CONFIG"

$CLI status --json | jq -e '.configured == true' >/dev/null 2>&1
check $? "a stowed (symlinked) config.json is read"

$CLI backup --dest test >/dev/null 2>&1
check $? "and a backup runs with it"

[ -L "$CONFIG" ]
check $? "and it is not swept away by the directory hardening"

rm -f "$CONFIG"
cp "$WORK/dotfiles/config.json" "$CONFIG"

# --- configuration errors --------------------------------------------------

group_restic "Configuration errors"

jq '.destinations[0].password_command = "echo x"
    | .destinations[0].password_file = "'"$XDG_CONFIG_HOME"'/omarchy-time-machine/test.key"' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
OUT="$($CLI backup --dest test 2>&1)"
grep -q "pick one" <<<"$OUT"
check $? "setting both password sources is refused rather than silently resolved"
cp "$WORK/config.bak" "$CONFIG"

jq '.exclude_file = "/nope/missing.txt"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI backup --dest test >/dev/null 2>&1
[ "$(find "$XDG_STATE_HOME/omarchy-time-machine" -maxdepth 1 -name '.summary.*' | wc -l)" = "0" ]
check $? "a failing run leaves no scratch files behind"
cp "$WORK/config.bak" "$CONFIG"

# --- failure handling ------------------------------------------------------

group_restic "Failure handling"

jq --arg r "$WORK/does-not-exist" \
   --arg c "printf hooked > $WORK/hook.txt" \
   '.destinations[0].repository = $r | .on_failure_command = $c' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
rm -f "$WORK/hook.txt"

$CLI backup --dest test >/dev/null 2>&1
jq -e '.destinations.test.last_run.result == "failed"' "$STATUS" >/dev/null 2>&1
check $? "a failed run is recorded as failed"

$CLI report-failure --dest test >/dev/null 2>&1
sleep 1
[ -f "$WORK/hook.txt" ]
check $? "the OnFailure path runs on_failure_command"

# The reason, not the exit code. restic reports fatal errors as JSON on stderr
# when --json is set, so it lands in the log rather than in the stdout stream
# and has to be dug back out of there.
jq -e '.destinations.test.last_run.error | test("repository does not exist")' \
  "$STATUS" >/dev/null 2>&1
check $? "a failure records why it failed, in restic's own words"

jq -e '.destinations.test.last_run.error | test("^Fatal") | not' "$STATUS" >/dev/null 2>&1
check $? "and without restic's Fatal: prefix"

$CLI status --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "status still emits valid JSON after a failure"

cp "$WORK/config.bak" "$CONFIG"

# --- staleness -------------------------------------------------------------

group_restic "Progress staleness"

PROGRESS="$XDG_STATE_HOME/omarchy-time-machine/progress-test.json"
jq '.state = "running" | .updated_epoch = (now - 600 | floor)' "$PROGRESS" > "$PROGRESS.n" && mv "$PROGRESS.n" "$PROGRESS"
$CLI status --json | jq -e '.destinations[0].running == false' >/dev/null 2>&1
check $? "a progress file older than the threshold is not treated as a running backup"

jq '.state = "running" | .updated_epoch = (now | floor)' "$PROGRESS" > "$PROGRESS.n" && mv "$PROGRESS.n" "$PROGRESS"
$CLI status --json | jq -e '.destinations[0].running == true' >/dev/null 2>&1
check $? "a fresh progress file is"

# --- systemd ---------------------------------------------------------------

group "systemd units"

$CLI install >/dev/null 2>&1
for unit in "omarchy-time-machine@.service" "omarchy-time-machine-failed@.service" "omarchy-time-machine@test.timer"; do
  [ -f "$XDG_CONFIG_HOME/systemd/user/$unit" ]
  check $? "install writes $unit"
done

# A timer starts its service through Unit=; it must not Require that service.
# Otherwise cancelling one running backup deactivates the long-lived timer and
# silently prevents every future scheduled backup.
! grep -q '^Requires=omarchy-time-machine@test.service$' \
  "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@test.timer"
check $? "cancelling a backup cannot deactivate its timer"

# restic exits 3 when it could not read a source file. The snapshot it writes
# then has holes in it, and calling that a success is how a backup rots
# unnoticed: the last snapshot that still held the file ages out, prune
# reclaims its data, and the icon stayed green throughout. So the unit must
# NOT excuse it -- OnFailure has to fire.
grep -q "SuccessExitStatus" "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@.service"
[ $? -ne 0 ]
check $? "the service does not excuse restic exit 3"

# install exits non-zero here because systemd cannot enable a unit under a
# redirected XDG_CONFIG_HOME. What is under test is that it rewrites nothing.
OUT="$($CLI install 2>&1)"
[ "$(grep -c 'unchanged' <<<"$OUT")" = "3" ]
check $? "install rewrites nothing on a second run"

if command -v systemd-analyze >/dev/null 2>&1; then
  (cd "$XDG_CONFIG_HOME/systemd/user" && systemd-analyze --user verify ./omarchy-time-machine@.service >/dev/null 2>&1)
  check $? "systemd accepts the generated service"
fi

# --- multiple destinations -------------------------------------------------

group_restic "Multiple destinations"

cp "$WORK/config.bak" "$CONFIG"
mkdir -p "$WORK/repo-b"
jq --arg r "$WORK/repo-b" '
  .destinations += [{name:"second", repository:$r, retention:{daily:2, weekly:1}}]' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

printf 'second-password\n' | $CLI key set --dest second >/dev/null 2>&1
$CLI init --dest second >/dev/null 2>&1
$CLI backup --dest second >/dev/null 2>&1
check $? "a second destination backs up independently"

[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "test,second" ]
check $? "status reports every destination"

# Every scheduled destination gets its own timer, whichever one is "active".
# Somebody with two destinations expects both to run overnight, and reading
# "active" as "the one that runs" would be a quiet way to lose half a backup
# strategy.
jq '.destinations[0].schedule = "*-*-* 03:00:00"
    | .destinations[1].schedule = "*-*-* 04:00:00"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI install >/dev/null 2>&1
[ -f "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@test.timer" ] \
  && [ -f "$XDG_CONFIG_HOME/systemd/user/omarchy-time-machine@second.timer" ]
check $? "each scheduled destination gets its own timer, active or not"
jq 'del(.destinations[].schedule)' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

# Per-destination retention overrides the global block key by key, rather than
# replacing it: `second` sets daily and weekly and inherits monthly and yearly.
grep -qh "keep 2 daily, 1 weekly, 12 monthly, 3 yearly" "$XDG_STATE_HOME/omarchy-time-machine/logs/second/"*.log
check $? "per-destination retention overrides key by key, not wholesale"

# A destination pointing at nothing must not take the others down with it.
jq '.destinations += [{name:"broken", repository:"/nonexistent/repo"}]' \
  "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI status --json | jq -e '.ok == true and (.destinations | length) == 3' >/dev/null 2>&1
check $? "a broken destination does not break status for the rest"

cp "$WORK/config.bak" "$CONFIG"

# --- labels and failure reporting ------------------------------------------

group_restic "Labels and failure state"

cp "$WORK/config.bak" "$CONFIG"
jq '.destinations[0].display_name = "The Big Disk"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
[ "$($CLI status --json | jq -r '.destinations[0].display_name')" = "The Big Disk" ]
check $? "display_name is reported separately from the identifier"

[ "$($CLI status --json | jq -r '.destinations[0].name')" = "test" ]
check $? "and the identifier is unchanged, so units and key files keep their names"

cp "$WORK/config.bak" "$CONFIG"
[ "$($CLI status --json | jq -r '.destinations[0].display_name')" = "test" ]
check $? "without display_name it falls back to the name"

# A failure must not erase the record of the last good backup: how stale your
# files now are is the thing you actually need after one.
jq --arg r "$WORK/gone" '.destinations[0].repository = $r' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI backup --dest test >/dev/null 2>&1
jq -e '.destinations.test.last_success_at != null and .destinations.test.last_run.result == "failed"' \
  "$STATUS" >/dev/null 2>&1
check $? "a failed run keeps the previous last_success_at"
cp "$WORK/config.bak" "$CONFIG"

# --- saving the key to 1Password -------------------------------------------
#
# Stubbed, because a test suite has no business touching somebody's vault. What
# is under test is the part that can leak: the secret must reach op on stdin,
# never as an argument, and the note that goes with it must not carry a
# password of its own.

group "Saving the key to 1Password"

mkdir -p "$WORK/stub"
cat > "$WORK/stub/op" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "vault list") echo '[{"name":"Private"}]' ;;
  "item get") exit 1 ;;
  "item create") printf '%s' "$*" > "$OP_ARGV"; cat > "$OP_CAPTURE"; exit 0 ;;
esac
STUB
chmod +x "$WORK/stub/op"

jq '.destinations[0].repository = "sftp:me:hunter2@nas:/volume1/backup"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
OP_ARGV="$WORK/op-argv" OP_CAPTURE="$WORK/op-stdin" PATH="$WORK/stub:$PATH" \
  $CLI key save-1password --dest test >/dev/null 2>&1

grep -q "test-password" "$WORK/op-argv" 2>/dev/null && false || true
check $? "the key never appears in op's arguments"

jq -e '.fields[0].value == "test-password"' "$WORK/op-stdin" >/dev/null 2>&1
check $? "it travels on stdin inside the item template"

grep -q "hunter2" "$WORK/op-stdin" 2>/dev/null && false || true
check $? "and the note names the destination without its password"

# op that is present but not signed in must fail immediately. A backup tool
# that can sit waiting on an authentication prompt is worse than one that stops.
cat > "$WORK/stub/op" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "vault" ] && { echo "not signed in" >&2; exit 1; }
sleep 300
STUB
chmod +x "$WORK/stub/op"
START="$(date +%s)"
PATH="$WORK/stub:$PATH" $CLI key save-1password --dest test >/dev/null 2>&1
[ "$(( $(date +%s) - START ))" -lt 5 ]
check $? "a 1Password that will not answer fails fast instead of hanging"

cp "$WORK/config.bak" "$CONFIG"

# --- more than one source ---------------------------------------------------

group_restic "Multiple sources"

mkdir -p "$WORK/extra"
echo "elsewhere" > "$WORK/extra/note.txt"
jq --arg a "$WORK/src" --arg b "$WORK/extra" '.source = [$a, $b]' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

$CLI backup --dest test >/dev/null 2>&1
[ "$($CLI snapshots --dest test --json | jq -r '.snapshots[0].paths | length')" = "2" ]
check $? "a list of sources ends up in one snapshot"

# Stop rather than quietly snapshot what is left. A source that vanished is
# usually an unmounted disk, and retention would happily thin out the good
# snapshots to keep the incomplete ones.
jq --arg m "$WORK/not-mounted" '.source += [$m]' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
OUT="$($CLI backup --dest test 2>&1)"
grep -q "source does not exist" <<<"$OUT"
check $? "a missing source stops the run instead of taking half a backup"

cp "$WORK/config.bak" "$CONFIG"
$CLI backup --dest test >/dev/null 2>&1
[ "$($CLI snapshots --dest test --json | jq -r '.snapshots[0].paths | length')" = "1" ]
check $? "and a plain string still works"

# --- listing destinations ---------------------------------------------------

group "Listing destinations"

OUT="$($CLI destinations 2>&1)"
grep -q "NAME" <<<"$OUT" && grep -q "test" <<<"$OUT"
check $? "destinations prints a readable table by default"

# Reads config and the local state file only. Somebody checking what they have
# should not have to wait on a sleeping NAS, or plug the drive back in.
jq '.destinations[0].repository = "sftp:nobody@203.0.113.1:/nowhere"' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
START="$(date +%s)"
$CLI destinations >/dev/null 2>&1
[ "$(( $(date +%s) - START ))" -lt 3 ]
check $? "and answers instantly with an unreachable destination"
cp "$WORK/config.bak" "$CONFIG"

$CLI destinations --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "--json still gives the widget its machine-readable form"

# --- a broken configuration ------------------------------------------------
#
# A config that exists but is wrong used to be indistinguishable from one that
# is missing, so the panel offered to create a file that was already there and
# said nothing about what was wrong with it.

group "Broken configuration"

cp "$CONFIG" "$WORK/config.good"

jq 'del(.destinations[0].name) | .destinations[0].display_name = "The Big Disk"' \
  "$WORK/config.good" > "$CONFIG"
$CLI status --json | jq -e '.configured == false and .invalid == true' >/dev/null 2>&1
check $? "a destination without a name reports invalid, not missing"

$CLI status --json | jq -e '.error | test("display_name")' >/dev/null 2>&1
check $? "and the message points at the mistake somebody actually makes"

echo 'not json at all' > "$CONFIG"
$CLI status --json | jq -e '.invalid == true' >/dev/null 2>&1
check $? "unparseable JSON reports invalid too"

rm -f "$CONFIG"
$CLI status --json | jq -e '.configured == false and .invalid == false' >/dev/null 2>&1
check $? "a missing file is reported as missing, not broken"

cp "$WORK/config.good" "$CONFIG"
$CLI status --json | jq -e '.configured == true and .invalid == false' >/dev/null 2>&1
check $? "and a good one is neither"

# --- starter configuration -------------------------------------------------

group "Starter configuration"

CONFIG_BACKUP="$WORK/config.keep"
cp "$CONFIG" "$CONFIG_BACKUP"
rm -f "$CONFIG"

$CLI config create >/dev/null 2>&1
jq -e '.destinations[0].repository | test("CHANGE-ME")' "$CONFIG" >/dev/null 2>&1
check $? "config create writes a starter file with an unmistakable placeholder"

[ "$(stat -c %a "$CONFIG")" = "600" ]
check $? "and it is not world readable"

# Refusing to overwrite matters more here than anywhere else: the file it would
# replace holds the only pointer to somebody's backups.
BEFORE="$(cat "$CONFIG")"
$CLI config create >/dev/null 2>&1
[ "$(cat "$CONFIG")" = "$BEFORE" ]
check $? "running it again leaves an existing configuration alone"

cp "$CONFIG_BACKUP" "$CONFIG"

# --- the settings view -----------------------------------------------------
#
# The panel edits config.json through `config show` and `config write`, and
# runs the setup steps through the --json forms of key, init and install.
# Everything it sends back must round-trip, and every answer must be one line
# of JSON on stdout -- prose belongs on stderr, where QML never looks.

group "Editing the configuration from the panel"

$CLI config show --json | jq -e '.ok == true and .exists == true and .config.destinations[0].name == "test"' >/dev/null 2>&1
check $? "config show --json hands the panel the whole file"

CONFIG_BACKUP="$WORK/config.before-panel"
cp "$CONFIG" "$CONFIG_BACKUP"

# A key this script knows nothing about must come back exactly as it went in:
# the form edits what it understands and passes the rest through.
jq '.destinations[0].display_name = "Drive in my bag" | .somebody_elses_key = {"kept": true}' "$CONFIG_BACKUP" \
  | $CLI config write --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "config write --json accepts a good configuration"

jq -e '.somebody_elses_key.kept == true and .destinations[0].display_name == "Drive in my bag"' "$CONFIG" >/dev/null 2>&1
check $? "and writes it back whole, unknown keys included"

[ "$(stat -c %a "$CONFIG")" = "600" ]
check $? "and the file is not world readable"

OUT="$(printf '{"destinations":[{"repository":"/x"}]}' | $CLI config write --json)"
jq -e '.ok == false and (.error | test("needs a name"))' >/dev/null 2>&1 <<<"$OUT"
check $? "a destination without a name is refused with the same message status gives"

jq -e '.somebody_elses_key.kept == true' "$CONFIG" >/dev/null 2>&1
check $? "and the file on disk is untouched by the refusal"

if command -v systemd-analyze >/dev/null 2>&1; then
  OUT="$(jq '.destinations[0].schedule = "every tuesday-ish"' "$CONFIG_BACKUP" | $CLI config write --json)"
  jq -e '.ok == false and (.error | test("schedule of test"))' >/dev/null 2>&1 <<<"$OUT"
  check $? "a schedule systemd would not accept is refused before the timer finds out"
fi

OUT="$(printf 'not json at all' | $CLI config write --json)"
jq -e '.ok == false' >/dev/null 2>&1 <<<"$OUT"
check $? "garbage is refused as JSON, not as a crash"

cp "$CONFIG_BACKUP" "$CONFIG"

# --- the exclude list, from the panel -----------------------------------------

group "Editing the exclude list from the panel"

EXCLUDES="$XDG_CONFIG_HOME/omarchy-time-machine/excludes.txt"
rm -f "$EXCLUDES"

# The suite's configuration points exclude_file at a file of its own. These
# checks are about the default -- excludes.txt next to config.json -- so the
# setting comes out for the duration and goes back at the end.
cp "$CONFIG" "$WORK/config.before-excludes"
jq 'del(.exclude_file)' "$WORK/config.before-excludes" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"

$CLI excludes show --json \
  | jq -e '.ok == true and .exists == false and .is_default == true and (.path | endswith("/excludes.txt")) and (.lines | length) == 0' >/dev/null 2>&1
check $? "excludes show --json reports where the list would go before there is one"

# The panel edits the pattern lines and hands back everything else untouched,
# so a comment explaining why something is skipped has to survive the trip.
printf '# the VM images, I can rebuild those\n\n/home/someone/VMs\n/home/someone/Downloads\n' \
  | $CLI excludes write --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "excludes write --json accepts a list"

$CLI excludes show --json \
  | jq -e '.lines == ["# the VM images, I can rebuild those", "", "/home/someone/VMs", "/home/someone/Downloads"]' >/dev/null 2>&1
check $? "and comments and blank lines come back exactly as they went in"

[ "$(stat -c %a "$EXCLUDES")" = "600" ]
check $? "and the file is not world readable"

[ "$(tail -c 2 "$EXCLUDES" | od -An -c | tr -d ' ')" = "s\\n" ]
check $? "and it ends in exactly one newline, because restic reads it line by line"

printf '' | $CLI excludes write --json | jq -e '.ok == true' >/dev/null 2>&1
check $? "an empty list is a legitimate answer, not an error"

[ ! -s "$EXCLUDES" ]
check $? "and it empties the file rather than leaving the old patterns behind"

OUT="$(head -c 300000 /dev/zero | tr '\0' 'x' | $CLI excludes write --json)"
jq -e '.ok == false and (.error | test("too long"))' >/dev/null 2>&1 <<<"$OUT"
check $? "something far too large to be a list of patterns is refused"

# An exclude_file the user pointed somewhere else is the one the panel edits:
# the panel must never resolve this path for itself.
ELSEWHERE="$WORK/dotfiles-excludes.txt"
jq --arg p "$ELSEWHERE" '.exclude_file = $p' "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
$CLI excludes show --json | jq -e --arg p "$ELSEWHERE" '.path == $p and .is_default == false' >/dev/null 2>&1
check $? "a configured exclude_file is the one show reports, and it says it is not the default"

printf '/home/someone/elsewhere\n' | $CLI excludes write --json >/dev/null 2>&1
[ "$(cat "$ELSEWHERE" 2>/dev/null)" = "/home/someone/elsewhere" ]
check $? "and the one write writes to"

cp "$WORK/config.before-excludes" "$CONFIG"
rm -f "$EXCLUDES" "$ELSEWHERE"

# --- the password, from the panel --------------------------------------------

group "The password, from the panel"

$CLI status --json | jq -e '.destinations[0].key_present == true' >/dev/null 2>&1
check $? "status reports that a key is present, without reading it"

OUT="$(printf 'test-password\n' | $CLI key set --dest test --json)"
[ "$(wc -l <<<"$OUT")" = "1" ] && jq -e '.ok == true and (.path | endswith("test.key"))' >/dev/null 2>&1 <<<"$OUT"
check $? "key set --json answers with one line of JSON and nothing else"

[ "$($CLI key show --dest test --json | jq -r '.key')" = "test-password" ]
check $? "key show --json returns the key for the panel to show or copy"

OUT="$($CLI key show --dest nope --json)"
jq -e '.ok == false' >/dev/null 2>&1 <<<"$OUT"
check $? "and an unknown destination is a JSON error, not a shell one"

KEYLESS="$WORK/keyless"
mkdir -p "$KEYLESS/config/omarchy-time-machine"
# Without the password_file that `key set` recorded above, or the fresh name
# would still resolve to the existing key.
jq '.destinations[0].name = "fresh" | del(.destinations[0].password_file)' "$CONFIG" \
  > "$KEYLESS/config/omarchy-time-machine/config.json"
XDG_CONFIG_HOME="$KEYLESS/config" XDG_STATE_HOME="$KEYLESS/state" $CLI status --json \
  | jq -e '.destinations[0].key_present == false' >/dev/null 2>&1
check $? "a destination without a key file says so"

# --- the repository and the schedule, from the panel ------------------------

group_restic "The repository, from the panel"

OUT="$($CLI init --dest test --json 2>/dev/null)"
[ "$(wc -l <<<"$OUT")" = "1" ] && jq -e '.ok == true and .already == true' >/dev/null 2>&1 <<<"$OUT"
check $? "init --json on an existing repository is a success that says so"

group "The schedule, from the panel"

# install cannot enable anything under a redirected XDG_CONFIG_HOME, and says
# so. What matters here is the shape of the answer: JSON alone on stdout.
OUT="$($CLI install --json 2>/dev/null)"
[ "$(wc -l <<<"$OUT")" = "1" ] && jq -e 'has("ok")' >/dev/null 2>&1 <<<"$OUT"
check $? "install --json keeps its commentary off stdout"

# Captured first, for the same pipefail reason as everywhere else in this file:
# grep -q hangs up as soon as it has its match, and the CLI is still talking.
ERR="$($CLI install --json 2>&1 >/dev/null)"
grep -q 'Writing units' <<<"$ERR"
check $? "and puts it on stderr instead"

# --- checking a destination ---------------------------------------------------
#
# The panel's Test Connection button. It must say which step failed, in words
# that name the fix, and it must never need the repository password to do so.

group "Checking a destination"

PROBE="$WORK/probe"
mkdir -p "$PROBE/config/omarchy-time-machine" "$PROBE/here"
probe_with() {  # $1 = repository
  jq --arg r "$1" '.destinations[0].repository = $r | del(.destinations[0].password_file)' "$CONFIG" \
    > "$PROBE/config/omarchy-time-machine/config.json"
  XDG_CONFIG_HOME="$PROBE/config" XDG_STATE_HOME="$PROBE/state" $CLI probe --dest test --json
}

probe_with "$PROBE/here" | jq -e '.ok == true and .ready == true and .stage == "ready"' >/dev/null 2>&1
check $? "a local folder that exists is ready"

probe_with "$PROBE/here/restic" | jq -e '.ready == true' >/dev/null 2>&1
check $? "so is a folder whose parent exists, since init creates it"

probe_with "$PROBE/nowhere/at/all" | jq -e '.ready == false and .stage == "mount" and (.message | test("plugged in"))' >/dev/null 2>&1
check $? "a missing folder asks whether the drive is mounted"

probe_with "sftp://nobody@127.0.0.1:1/volume1/backup" | jq -e '.ready == false and .stage == "ssh_off" and (.message | test("Enable SSH"))' >/dev/null 2>&1
check $? "a NAS with nothing on the SSH port is told where the switch is"

probe_with "sftp:nobody@" | jq -e '.ok == false' >/dev/null 2>&1
check $? "a malformed sftp address is refused as such"

probe_with "s3:s3.amazonaws.com/bucket" | jq -e '.ready == false and .stage == "untested"' >/dev/null 2>&1
check $? "a cloud destination says it cannot be checked from here"

ls "$PROBE/config/omarchy-time-machine/"*.key >/dev/null 2>&1
[ $? -ne 0 ]
check $? "and none of that needed a key file"

OUT="$(XDG_CONFIG_HOME="$PROBE/config" $CLI ssh install-key --dest test 2>&1)"
grep -q "not an sftp" <<<"$OUT"
check $? "install-key refuses a destination that is not a NAS"

# --- demo mode -------------------------------------------------------------
#
# Screenshots must never show a real home directory, and a click while posing
# must not reach a real repository.

group_restic "Demo mode"

$CLI demo on >/dev/null 2>&1
[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "nas,usb,offsite" ]
check $? "demo mode serves invented destinations"

OUT="$($CLI backup --dest test 2>&1)"
grep -q "refusing to run a real backup" <<<"$OUT"
check $? "demo mode makes backup a no-op"

$CLI demo off >/dev/null 2>&1
[ "$($CLI status --json | jq -r '[.destinations[].name] | join(",")')" = "test" ]
check $? "turning demo off restores the real configuration"

# --- result ----------------------------------------------------------------

if [ "$SKIPPED" -gt 0 ]; then
  printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
  [ "$HAVE_RESTIC" = "0" ] && printf 'restic is not installed, so every test that needs a repository was skipped.\n'
else
  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
fi
[ "$FAILED" = "0" ]
