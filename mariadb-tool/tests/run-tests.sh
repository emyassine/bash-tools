#!/usr/bin/env bash
# Test suite for mariadb-manager.sh.
# Uses a FAKE mariadb client (tests/fake-bin) and temporary directories only:
# no real MariaDB server and no production data are involved.
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${MDBM_SCRIPT:-$HERE/../mariadb-manager.sh}"
PASS=0; FAIL=0; T=''

assert() { # assert DESCRIPTION COMMAND...
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf '  PASS  %s\n' "$desc"
    else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$desc"; fi
}
section() { printf '\n%s\n' "$1"; }

new_env() {
    T="$(mktemp -d)"
    cp "$SCRIPT" "$T/mariadb-manager.sh"
    export FAKE_DB_DIR="$T/db" MDBM_TEST_MODE=1 HIST="$T/mariadb-manager.sh.history"
    mkdir -p "$T/bin"; cp "$HERE"/fake-bin/mariadb "$HERE"/fake-bin/ss "$T/bin/"; chmod +x "$T"/bin/*
    export PATH="$T/bin:$ORIG_PATH"
    unset FAKE_FAIL_ON FAKE_SLEEP_AFTER_GRANT FAKE_BREAK_HISTORY FAKE_SS_ADDR
    mkdir -p "$FAKE_DB_DIR"
    printf 'shopdb\t12\t1.50\nblogdb\t5\t0.20\nunder_score\t1\t0.01\nunderXscore\t1\t0.01\n' >"$FAKE_DB_DIR/databases"
    printf 'root\tlocalhost\napp\tlocalhost\nblog\tlocalhost\n' >"$FAKE_DB_DIR/users"
    printf 'version\t11.4.0-fake\nhostname\ttesthost\nport\t3306\nbind_address\t127.0.0.1\nskip_networking\tOFF\n' >"$FAKE_DB_DIR/variables"
    : >"$FAKE_DB_DIR/dbgrants"; : >"$FAKE_DB_DIR/tableprivs"; : >"$FAKE_DB_DIR/globals"; : >"$FAKE_DB_DIR/sql.log"
}
run_cli() { # run_cli "INPUT" ARGS...   (INPUT uses printf %b escapes)
    local input="$1"; shift
    OUT="$(printf '%b' "$input" | bash "$T/mariadb-manager.sh" "$@" 2>&1)"; RC=$?
}
out_has()   { grep -Fq -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -Fq -- "$1" <<<"$OUT"; }
has_user()  { grep -Fxq "$1"$'\t'"$2" "$FAKE_DB_DIR/users"; }
has_row()   { grep -Fxq "$1"$'\t'"$2"$'\t'"$3" "$FAKE_DB_DIR/dbgrants"; }
rows()      { wc -l <"$FAKE_DB_DIR/dbgrants" | tr -d ' '; }
hist_has()  { grep -Eq -- "$1" "$HIST"; }
log_lacks() { ! grep -Eq -- "$1" "$FAKE_DB_DIR/sql.log"; }
log_has()   { grep -Eq -- "$1" "$FAKE_DB_DIR/sql.log"; }
rows_is()   { [[ "$(rows)" == "$1" ]]; }
last_hist() { [[ "$(tail -n 1 "$HIST" | cut -f1)" == "$1" ]]; }
NEWPW='shopdb\napp\npw1\npw1\nGRANT\n'
ORIG_PATH="$PATH"

section '1. Creation of a new remote account'
new_env; run_cli "$NEWPW" grant
assert 'account app@% is created'                    has_user app '%'
assert 'privileges are on shopdb only'               has_row app '%' shopdb
assert 'exactly one privilege row exists'            rows_is 1
assert 'PENDING record is written first'             hist_has $'^PENDING\tshopdb\tapp\t'
assert 'ACTIVE record is written with YES and NONE'  hist_has $'^ACTIVE\tshopdb\tapp\t[^\t]+\tYES\tNONE$'
assert 'success is reported'                         out_has "Created app@'%'"
assert 'tells that the application needs no change'  out_has 'same host, same username, same password'
assert 'network verdict warns about loopback'        out_has 'only on the loopback interface'

section '2. Database names with _ are matched literally (no wildcard)'
new_env; run_cli 'under_score\napp\npw1\npw1\nGRANT\n' grant
assert 'the stored pattern is escaped'               has_row app '%' 'under\_score'
assert 'ACTIVE record exists'                        hist_has $'^ACTIVE\tunder_score\tapp\t'

section '3. Reuse of an existing remote account without privileges'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; run_cli 'shopdb\napp\nGRANT\n' grant
assert 'no CREATE USER is executed'                  log_lacks 'CREATE USER'
assert 'privilege row is added'                      has_row app '%' shopdb
assert 'ACTIVE record says NO and NONE'              hist_has $'^ACTIVE\tshopdb\tapp\t[^\t]+\tNO\tNONE$'
assert 'password is not requested'                   out_lacks 'Password:'

section '4. Reuse refused when privileges already exist (incl. escaped and wildcard rows)'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tshopdb\n' >"$FAKE_DB_DIR/dbgrants"
run_cli 'shopdb\napp\nquit\n' grant
assert 'exact existing row: refused'                 out_has 'already has privileges'
assert 'exact existing row: nothing changed'         rows_is 1
assert 'exact existing row: no GRANT executed'       log_lacks '^GRANT'
assert 'exact existing row: no history written'      test ! -e "$HIST"
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tunder\\_score\n' >"$FAKE_DB_DIR/dbgrants"
run_cli 'under_score\napp\nquit\n' grant
assert 'escaped existing row (the reported bug): refused' out_has 'already has privileges'
assert 'escaped existing row: no GRANT executed'     log_lacks '^GRANT'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tunder%%\n' >"$FAKE_DB_DIR/dbgrants"
run_cli 'under_score\napp\nquit\n' grant
assert 'wildcard existing row: refused'              out_has 'already has privileges'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tshopdb\ttable1\n' >"$FAKE_DB_DIR/tableprivs"
run_cli 'shopdb\napp\nquit\n' grant
assert 'table-level existing privilege: refused'     out_has 'already has privileges'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\n' >"$FAKE_DB_DIR/globals"
run_cli 'shopdb\napp\nquit\n' grant
assert 'global privileges: refused'                  out_has 'global or role-based grants'
assert 'global privileges: no GRANT executed'        log_lacks '^GRANT'

section '5. SQL failure leaves nothing behind'
new_env; export FAKE_FAIL_ON=GRANT; run_cli "$NEWPW" grant
assert 'rejection is reported'                       out_has 'MariaDB rejected the request'
assert 'half-created account is removed'             bash -c '! grep -Fxq "app	%" "$FAKE_DB_DIR/users"'
assert 'rollback is announced'                       out_has 'Rolled back'
assert 'history ends with ABORTED'                   last_hist ABORTED
assert 'no ACTIVE record exists'                     bash -c '! grep -q "^ACTIVE" "$HIST"'
new_env; export FAKE_FAIL_ON=GRANT; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; run_cli 'shopdb\napp\nGRANT\n' grant
assert 'reused account survives a failed grant'      has_user app '%'
assert 'reused account gets no privileges'           rows_is 0

section '6. History problems'
new_env; mkdir "$HIST"; run_cli "$NEWPW" grant
assert 'unwritable history: MariaDB is not touched'  log_lacks 'CREATE USER'
assert 'unwritable history: clear message'           out_has 'Cannot write the history file'
assert 'unwritable history: no account created'      bash -c '! grep -Fxq "app	%" "$FAKE_DB_DIR/users"'
new_env; export FAKE_BREAK_HISTORY="$HIST"; run_cli "$NEWPW" grant
assert 'history lost after grant: reported'          out_has 'could not be recorded'
assert 'history lost after grant: account dropped'   bash -c '! grep -Fxq "app	%" "$FAKE_DB_DIR/users"'
assert 'history lost after grant: no privileges'     rows_is 0
rm -rf "$HIST"

section '7. Interruption (SIGTERM) after the grant, before it is recorded'
new_env; export FAKE_SLEEP_AFTER_GRANT=3
( printf '%b' "$NEWPW" | bash "$T/mariadb-manager.sh" grant >"$T/out.txt" 2>&1 ) &
BG=$!; sleep 1.2; pkill -TERM -f "$T/mariadb-manager.sh" ; wait "$BG" 2>/dev/null
OUT="$(cat "$T/out.txt")"
assert 'interruption is announced'                   out_has 'interrupted'
assert 'account is rolled back'                      bash -c '! grep -Fxq "app	%" "$FAKE_DB_DIR/users"'
assert 'history ends with ABORTED'                   last_hist ABORTED
unset FAKE_SLEEP_AFTER_GRANT

section '8. Revocation'
new_env; run_cli "$NEWPW" grant; run_cli '1\nREVOKE\n' revoke
assert 'created account is dropped'                  bash -c '! grep -Fxq "app	%" "$FAKE_DB_DIR/users"'
assert 'REVOKED record is written'                   last_hist REVOKED
assert 'localhost account is untouched'              has_user app localhost
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tblogdb\n' >"$FAKE_DB_DIR/dbgrants"
run_cli 'shopdb\napp\nGRANT\n' grant; run_cli '1\nREVOKE\n' revoke
assert 'reused account is kept'                      has_user app '%'
assert 'only the added privileges are removed'       bash -c '! grep -Fxq "app	%	shopdb" "$FAKE_DB_DIR/dbgrants"'
assert 'pre-existing privileges on other DB remain'  has_row app '%' blogdb
new_env; run_cli "$NEWPW" grant; printf 'app\t%%\tblogdb\n' >>"$FAKE_DB_DIR/dbgrants"; run_cli '1\nREVOKE\n' revoke
assert 'account with newer privileges is NOT dropped' has_user app '%'
assert 'newer privileges are preserved'              has_row app '%' blogdb
assert 'tool-added privileges are removed'           bash -c '! grep -Fxq "app	%	shopdb" "$FAKE_DB_DIR/dbgrants"'
new_env; run_cli "$NEWPW" grant; run_cli '1\nREVOKE\n' revoke; run_cli '1\n' revoke
assert 'nothing left to revoke afterwards'           out_has 'No active remote grants'

section '9. Legacy record (older version, reused account) is never auto-revoked'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tshopdb\n' >"$FAKE_DB_DIR/dbgrants"
printf 'ACTIVE\tshopdb\tapp\t2026-11-26T10:24:45+01:00\tNO\n' >"$HIST"
run_cli '1\nREVOKE\nback\nquit\n' revoke
assert 'older-version warning is shown'              out_has 'older version'
assert 'REVOKE is refused'                           out_has 'Type FORGET'
assert 'privileges untouched by REVOKE input'        has_row app '%' shopdb
assert 'no REVOKE statement executed'                log_lacks '^REVOKE'
run_cli '1\nFORGET\n' revoke
assert 'FORGET only edits the history'               last_hist REVOKED
assert 'FORGET leaves MariaDB untouched'             has_row app '%' shopdb
assert 'FORGET executes no SQL write'                log_lacks '^(REVOKE|DROP|GRANT|CREATE)'

section '10. Missing history never revokes or removes anything'
new_env; printf 'app\t%%\n' >>"$FAKE_DB_DIR/users"; printf 'app\t%%\tshopdb\n' >"$FAKE_DB_DIR/dbgrants"
run_cli '' revoke
assert 'revoke finds nothing to do'                  out_has 'No active remote grants'
assert 'account still exists'                        has_user app '%'
assert 'privileges still exist'                      has_row app '%' shopdb
run_cli '' remote
assert 'remote view lists the untracked account'     out_has 'app@%'
assert 'remote view says untracked ones are never modified' out_has 'never modified or removed'

section '11. Legacy history file detection and import'
new_env; printf 'ACTIVE\tshopdb\tapp\t2026-11-01T09:00:00+01:00\tYES\n' >"$T/remote-db-access.sh.history"
run_cli 'q\n' menu
assert 'warns that a legacy history exists'          out_has 'Legacy history found'
assert 'states it is not read automatically'         out_has 'NOT read automatically'
run_cli 'back\n' migrate
assert 'back cancels the import'                     test ! -e "$HIST"
run_cli 'IMPORT\n' migrate
assert 'import copies the record'                    hist_has $'^ACTIVE\tshopdb\tapp\t'
assert 'import changes nothing in MariaDB'           log_lacks '^(REVOKE|DROP|GRANT|CREATE)'
run_cli 'q\n' menu
assert 'no legacy warning after import'              out_lacks 'Legacy history found'

section '12. Network diagnosis (read-only)'
new_env; export FAKE_SS_ADDR='127.0.0.1:3306'; run_cli '' diagnose
assert 'loopback-only listening is flagged'          out_has 'only on the loopback interface'
assert 'tells how, without doing it'                 out_has 'restart the service'
assert 'no write statement was executed'             log_lacks '^(REVOKE|DROP|GRANT|CREATE)'
export FAKE_SS_ADDR='0.0.0.0:3306'; run_cli '' diagnose
assert 'public listening is reported'                out_has 'non-loopback address'
unset FAKE_SS_ADDR; run_cli '' diagnose
assert 'falls back to the bind_address variable'     out_has 'only on the loopback interface'

section '13. Interrupted operation notice'
new_env; printf 'PENDING\tshopdb\tapp\t2026-11-26T10:00:00+01:00\tYES\tNONE\n' >"$HIST"
run_cli 'q\n' menu
assert 'interrupted operation is reported at start'  out_has 'Interrupted operation found'
run_cli '' remote
assert 'remote view lists it'                        out_has 'needing attention'
run_cli '1\nFORGET\n' revoke
assert 'FORGET closes it with ABORTED'               last_hist ABORTED

section '14. Navigation and existing commands'
new_env; run_cli 'shopdb\nback\nquit\n' grant
step1_twice() { [[ "$(grep -c 'Step 1/4' <<<"$OUT")" -ge 2 ]]; }
assert 'back from step 2 returns to step 1'          step1_twice
new_env; run_cli 'back\n' grant
assert 'back at step 1 leaves the wizard'            out_lacks 'Step 2/4'
new_env; run_cli '' databases; assert 'databases command'  out_has 'shopdb'
run_cli '' users;              assert 'users command'      out_has 'app@localhost'
run_cli '' info;               assert 'info command'       out_has 'bind_address'
run_cli '' remote;             assert 'remote command'     out_has 'Remote access overview'
run_cli '1\nq\n' menu;         assert 'menu lists databases' out_has 'blogdb'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
