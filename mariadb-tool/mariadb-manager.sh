#!/usr/bin/env bash
# MariaDB Manager
# Interactive CLI to inspect MariaDB and grant/revoke temporary, database-scoped
# remote access. History is kept beside this script so revocation only ever
# touches accounts and grants that this tool created.
set -Eeuo pipefail

VERSION='2.1.1'
EDITION='2026'
RELEASED='November 26, 2026'
RELEASE_NOTES='Safer exact-grant revocation; preserve later wildcard and object-level privileges; verify managed grant removal.'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
HISTORY_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.history"
LOCK_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.lock"
MARIADB_BIN="$(command -v mariadb || true)"
TEST_MODE="${MDBM_TEST_MODE:-}"   # tests only: skips the root and terminal checks

# A grant that was started by this run and is not yet fully recorded.
INFLIGHT_KIND=''   # create | reuse
INFLIGHT_USER=''
INFLIGHT_DB=''

# Globals used by the list picker and the list loaders.
PICK_LABELS=()
PICK_KEYS=()
PICK_INDEX=0
DB_NAMES=(); DB_LABELS=()
USER_NAMES=(); USER_HOSTS=(); USER_LABELS=()

# ---------------------------------------------------------------- output ----
use_color() { [[ -t "$1" && -z "${NO_COLOR:-}" ]]; }
if use_color 1; then
    RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    BLUE=$'\033[34m'; CYAN=$'\033[36m'
else
    RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''
fi

title() { printf '\n%s%s== %s ==%s\n' "$BOLD" "$BLUE" "$1" "$RESET"; }
ok()    { printf '  %s[OK]%s    %s\n' "$GREEN$BOLD" "$RESET" "$*"; }
info()  { printf '  %s[i]%s     %s\n' "$CYAN$BOLD" "$RESET" "$*"; }
warn()  { printf '  %s[!]%s     %s\n' "$YELLOW$BOLD" "$RESET" "$*"; }
err()   { printf '  %s[ERROR]%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; }
note()  { printf '  %s\n' "$*"; }
hint()  { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
die()   { err "$1"; exit "${2:-1}"; }
nav_hint() { hint "Navigation: type 'back' (or b) to go back, 'quit' (or q) to exit."; }

usage() {
    cat <<EOF_HELP
${SCRIPT_NAME} ${VERSION} - MariaDB Manager

Usage:
  ${SCRIPT_NAME}              Open the interactive menu
  ${SCRIPT_NAME} databases    List databases (size and table count)
  ${SCRIPT_NAME} users        List MariaDB accounts
  ${SCRIPT_NAME} remote       Show remote access overview
  ${SCRIPT_NAME} info         Show server information
  ${SCRIPT_NAME} diagnose     Check whether MariaDB accepts remote connections
  ${SCRIPT_NAME} grant        Start the "grant remote access" wizard
  ${SCRIPT_NAME} revoke       Start the "revoke remote access" wizard
  ${SCRIPT_NAME} migrate      Review and import a legacy history file
  ${SCRIPT_NAME} --version    Print version information
  ${SCRIPT_NAME} --help       Show this help

Navigation inside any wizard or menu:
  back | b      Go back one step
  quit | q      Exit immediately
  (password prompts use :back and :quit instead)

Remote grants create (or reuse) an account for host '%' with privileges on ONE
database only. Revocation only removes what this tool added. Network listening
(bind-address) and the firewall are never changed by this tool.
EOF_HELP
}

COMMAND=''
case "${1:-}" in
    --version|-v)
        printf '%s %s (edition %s, released %s)\n%s\n' "$SCRIPT_NAME" "$VERSION" "$EDITION" "$RELEASED" "$RELEASE_NOTES"
        exit 0
        ;;
    --help|-h) usage; exit 0 ;;
    ''|menu) COMMAND='menu' ;;
    databases|users|remote|info|diagnose|grant|revoke|migrate) COMMAND="$1" ;;
    *) err "Unknown option: $1"; usage >&2; exit 2 ;;
esac

# ------------------------------------------------------------ preflight -----
if [[ -n "$TEST_MODE" ]]; then
    warn 'TEST MODE: root and terminal checks are skipped.'
else
    [[ "${EUID}" -eq 0 ]] || die 'Run this script as root.'
fi
[[ -n "$MARIADB_BIN" ]] || die 'The mariadb client was not found.'
command -v flock >/dev/null 2>&1 || die 'The flock command is required.'

db_query() {
    "$MARIADB_BIN" --batch --skip-column-names --raw "$@"
}

umask 077

case "$COMMAND" in
    menu|grant|revoke|migrate)
        [[ -n "$TEST_MODE" || -t 0 ]] || die 'This command is interactive and needs a terminal.'
        exec 9>"$LOCK_FILE" || die "Cannot open lock file: $LOCK_FILE"
        flock -n 9 || die 'Another copy of this script is already running.'
        ;;
esac

if ! db_query --connect-timeout=5 -e 'SELECT 1' >/dev/null 2>&1; then
    die 'Cannot connect to MariaDB as root through the local socket.'
fi

if [[ -L "$HISTORY_FILE" ]]; then
    die 'Refusing to use a symlink as the history file.'
fi

# ----------------------------------------------------------- SQL helpers ----
sql_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

# Escapes the LIKE wildcards of a database name: in GRANT statements an
# unescaped _ or % matches other databases too.
like_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//_/\\_}"
    value="${value//\%/\\%}"
    printf '%s' "$value"
}

# Identifier used in GRANT: matches this ONE database only.
grant_identifier() {
    local value
    value="$(like_escape "$1")"
    value="${value//\`/\`\`}"
    printf '`%s`' "$value"
}

remote_account_count() { # remote_account_count USER
    db_query -e "SELECT COUNT(*) FROM mysql.user WHERE User = '$(sql_value "$1")' AND Host = '%';"
}

# Number of privilege rows of USER@'%' that touch DATABASE: database-level rows
# (wildcards honoured, exactly like MariaDB does), table, column and routine rows.
count_db_privileges() { # count_db_privileges USER DATABASE
    local u d
    u="$(sql_value "$1")"; d="$(sql_value "$2")"
    db_query -e "SELECT (SELECT COUNT(*) FROM mysql.db WHERE User = '${u}' AND Host = '%' AND '${d}' LIKE Db) + (SELECT COUNT(*) FROM mysql.tables_priv WHERE User = '${u}' AND Host = '%' AND Db = '${d}') + (SELECT COUNT(*) FROM mysql.columns_priv WHERE User = '${u}' AND Host = '%' AND Db = '${d}') + (SELECT COUNT(*) FROM mysql.procs_priv WHERE User = '${u}' AND Host = '%' AND Db = '${d}');"
}

# Number of privilege rows that do not belong to this tool's exact database
# grant. Database wildcard rows and object-level grants are additional access,
# even when they happen to cover DATABASE.
count_other_privileges() { # count_other_privileges USER DATABASE
    local u d
    u="$(sql_value "$1")"
    d="$(sql_value "$(like_escape "$2")")"
    db_query -e "SELECT (SELECT COUNT(*) FROM mysql.db WHERE User = '${u}' AND Host = '%' AND NOT (Db = '${d}')) + (SELECT COUNT(*) FROM mysql.tables_priv WHERE User = '${u}' AND Host = '%') + (SELECT COUNT(*) FROM mysql.columns_priv WHERE User = '${u}' AND Host = '%') + (SELECT COUNT(*) FROM mysql.procs_priv WHERE User = '${u}' AND Host = '%');"
}

# Count only the database-level rows this tool knows how to remove. Other
# grants may still cover the same database and must not keep this history entry
# active after the exact grant has been removed.
count_exact_db_rows() { # count_exact_db_rows USER DATABASE
    local u d_raw d_esc
    u="$(sql_value "$1")"
    d_raw="$(sql_value "$2")"
    d_esc="$(sql_value "$(like_escape "$2")")"
    db_query -e "SELECT COUNT(*) FROM mysql.db WHERE User = '${u}' AND Host = '%' AND Db IN ('${d_esc}', '${d_raw}');"
}

# Returns 0 when USER@'%' has global privileges or roles, 1 when it has not,
# 2 when the grants could not be read.
has_broad_grants() { # has_broad_grants USER
    local grants global_grants role_grants
    grants="$(db_query -e "SHOW GRANTS FOR '$(sql_value "$1")'@'%';")" || return 2
    global_grants="$(grep -F 'ON *.* TO' <<<"$grants" | grep -Fv 'GRANT USAGE ON' || true)"
    role_grants="$(grep -E '^GRANT ' <<<"$grants" | grep -Fv ' ON ' || true)"
    [[ -n "$global_grants" || -n "$role_grants" ]]
}

# Revokes the database-level rows that were stored for exactly this database
# (escaped form, or the raw form written by older versions). Other rows,
# including wildcard rows that happen to match, are never touched.
revoke_db_rows() { # revoke_db_rows USER DATABASE
    local u d_raw d_esc rows row ident
    u="$(sql_value "$1")"
    d_raw="$(sql_value "$2")"
    d_esc="$(sql_value "$(like_escape "$2")")"
    rows="$(db_query -e "SELECT Db FROM mysql.db WHERE User = '${u}' AND Host = '%' AND Db IN ('${d_esc}', '${d_raw}');")" || return 1
    [[ -n "$rows" ]] || return 0
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        ident="${row//\`/\`\`}"
        db_query -e "REVOKE ALL PRIVILEGES, GRANT OPTION ON \`${ident}\`.* FROM '${u}'@'%';" || return 1
    done <<<"$rows"
}

show_var() { # show_var NAME
    db_query -e "SHOW GLOBAL VARIABLES WHERE Variable_name = '$1';" 2>/dev/null | awk -F '\t' '{ print $2 }' || true
}

# --------------------------------------------------------------- history ----
# Records (tab separated):
#   PENDING  db user time created pre   written BEFORE MariaDB is changed
#   ACTIVE   db user time created pre   written after the grant is verified
#   ABORTED  db user time reason        the pending operation was rolled back
#   REVOKED  db user time               the grant was removed
# created = YES (account created by this tool) | NO (existing account reused)
# pre     = NONE (verified: no privileges on that database before the grant)
#           Older versions did not record it, so reused-account entries without
#           pre=NONE are never revoked automatically.
history_append() { # history_append FIELD...
    local line
    line="$(printf '%s\t' "$@")"
    line="${line%$'\t'}"
    { printf '%s\n' "$line" >>"$HISTORY_FILE"; } 2>/dev/null || return 1
    chmod 600 "$HISTORY_FILE" 2>/dev/null || return 1
    [[ "$(tail -n 1 "$HISTORY_FILE" 2>/dev/null)" == "$line" ]] || return 1
}

history_records() { # history_records active|pending
    [[ -f "$HISTORY_FILE" ]] || return 0
    awk -F '\t' -v want="$1" '
        $1 == "PENDING" { p[$2 SUBSEP $3] = $0 }
        $1 == "ACTIVE"  { a[$2 SUBSEP $3] = $0; delete p[$2 SUBSEP $3] }
        $1 == "REVOKED" { delete a[$2 SUBSEP $3] }
        $1 == "ABORTED" { delete p[$2 SUBSEP $3] }
        END {
            if (want == "active") { for (k in a) print a[k] }
            else                  { for (k in p) print p[k] }
        }
    ' "$HISTORY_FILE" | sort -t $'\t' -k4
}
active_grants()      { history_records active; }
pending_operations() { history_records pending; }

# Lines found in other *.history files beside this script that are not in the
# current history. They are never read automatically.
LEGACY_FILES=(); LEGACY_LINES=()
collect_legacy() {
    LEGACY_FILES=(); LEGACY_LINES=()
    local f line
    for f in "$SCRIPT_DIR"/*.history; do
        [[ -f "$f" && ! -L "$f" && "$f" != "$HISTORY_FILE" ]] || continue
        while IFS= read -r line; do
            case "$line" in ACTIVE$'\t'*|REVOKED$'\t'*|PENDING$'\t'*|ABORTED$'\t'*) ;; *) continue ;; esac
            if [[ -f "$HISTORY_FILE" ]] && grep -Fxq -- "$line" "$HISTORY_FILE"; then continue; fi
            LEGACY_FILES+=("$f"); LEGACY_LINES+=("$line")
        done <"$f"
    done
}

# ------------------------------------------------------ rollback / traps ----
# Undoes a grant started by this run. Returns 0 when MariaDB is back to the
# state it had before the grant.
rollback_inflight() {
    [[ -n "$INFLIGHT_KIND" ]] || return 0
    local status=0 kind="$INFLIGHT_KIND" user="$INFLIGHT_USER" db="$INFLIGHT_DB"
    if [[ "$kind" == 'create' ]]; then
        db_query -e "DROP USER IF EXISTS '$(sql_value "$user")'@'%';" >/dev/null 2>&1 || status=1
    else
        revoke_db_rows "$user" "$db" >/dev/null 2>&1 || status=1
    fi
    INFLIGHT_KIND=''
    if (( status == 0 )); then
        ok "Rolled back: ${user}@'%' has no new access to ${db}. MariaDB is back to its previous state."
        if ! history_append ABORTED "$db" "$user" "$(date -Is)" 'rolled back'; then
            warn "The history file could not be updated; it may still list a PENDING entry. MariaDB itself is clean."
        fi
    else
        err "Rollback FAILED. ${user}@'%' may still have access to ${db}."
        err "Inspect it with: SHOW GRANTS FOR '${user}'@'%';"
        if [[ "$kind" == 'create' ]]; then
            err "Remove it with:  DROP USER '${user}'@'%';"
        else
            err "Remove it with:  REVOKE ALL PRIVILEGES ON $(grant_identifier "$db").* FROM '${user}'@'%';"
        fi
    fi
    return "$status"
}

cleanup() {
    if [[ -n "$INFLIGHT_KIND" ]]; then
        printf '\n'
        warn 'Operation interrupted before it was fully recorded. Rolling back...'
        rollback_inflight || true
    fi
}
trap cleanup EXIT
trap 'printf "\n"; warn "Interrupted."; exit 130' INT TERM

# ----------------------------------------------------------- navigation -----
bye() { printf '\n  %sGoodbye.%s\n' "$DIM" "$RESET"; exit 0; }

# ask VAR LABEL [secret]
# Returns 0 with the value stored in VAR, or 10 when the user typed "back".
# Exits when the user types "quit".
ask() {
    local __var="$1" __label="$2" __secret="${3:-}" __input __lower
    while true; do
        if [[ "$__secret" == 'secret' ]]; then
            read -r -s -p "  ${BOLD}${__label}${RESET} " __input || bye
            printf '\n'
        else
            read -r -p "  ${BOLD}${__label}${RESET} " __input || bye
            __input="${__input#"${__input%%[![:space:]]*}"}"
            __input="${__input%"${__input##*[![:space:]]}"}"
        fi
        __lower="${__input,,}"
        if [[ "$__secret" == 'secret' ]]; then
            case "$__lower" in
                ':back') return 10 ;;
                ':quit') bye ;;
            esac
        else
            case "$__lower" in
                b|back) return 10 ;;
                q|quit|exit) bye ;;
            esac
        fi
        printf -v "$__var" '%s' "$__input"
        return 0
    done
}

# pick_index LABEL   (uses PICK_LABELS / PICK_KEYS, sets PICK_INDEX)
pick_index() {
    local label="$1" answer i count="${#PICK_LABELS[@]}"
    for ((i = 0; i < count; i++)); do
        printf '    %s%3d)%s %s\n' "$CYAN" $((i + 1)) "$RESET" "${PICK_LABELS[i]}"
    done
    printf '\n'
    while true; do
        ask answer "$label" || return $?
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
            PICK_INDEX=$((answer - 1))
            return 0
        fi
        for ((i = 0; i < count; i++)); do
            if [[ "${PICK_KEYS[i]}" == "$answer" ]]; then
                PICK_INDEX=$i
                return 0
            fi
        done
        err "Not a valid choice. Enter a number from 1 to ${count}, or the exact name."
    done
}

# ------------------------------------------------------------- data ---------
load_databases() {
    DB_NAMES=(); DB_LABELS=()
    local name tables size
    while IFS=$'\t' read -r name tables size; do
        [[ -n "$name" ]] || continue
        DB_NAMES+=("$name")
        DB_LABELS+=("$(printf '%-32s %5s tables %10s MB' "$name" "$tables" "$size")")
    done < <(db_query -e "SELECT s.SCHEMA_NAME, COUNT(t.TABLE_NAME), ROUND(COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0) / 1024 / 1024, 2) FROM information_schema.SCHEMATA s LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME WHERE s.SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') GROUP BY s.SCHEMA_NAME ORDER BY s.SCHEMA_NAME;")
}

load_users() {
    USER_NAMES=(); USER_HOSTS=(); USER_LABELS=()
    local u h label managed_list
    managed_list="$(active_grants | awk -F '\t' '{ print $3 }')"
    while IFS=$'\t' read -r u h; do
        [[ -n "$u" ]] || continue
        USER_NAMES+=("$u")
        USER_HOSTS+=("$h")
        label="$(printf '%-40s' "${u}@${h}")"
        if [[ "$h" == '%' ]]; then
            if grep -Fxq -- "$u" <<<"$managed_list"; then
                label="${YELLOW}${label}${RESET} (remote, managed by this tool)"
            else
                label="${YELLOW}${label}${RESET} (remote)"
            fi
        fi
        USER_LABELS+=("$label")
    done < <(db_query -e "SELECT User, Host FROM mysql.user WHERE User <> '' ORDER BY User, Host;")
}

# ------------------------------------------------------- read-only views ----
view_databases() {
    title 'Databases'
    load_databases
    if (( ${#DB_NAMES[@]} == 0 )); then
        info 'No user databases found.'
        return 0
    fi
    local label
    for label in "${DB_LABELS[@]}"; do printf '    %s\n' "$label"; done
    printf '\n'
    hint 'System databases (mysql, sys, information_schema, performance_schema) are hidden.'
}

view_users() {
    title 'MariaDB accounts'
    load_users
    if (( ${#USER_NAMES[@]} == 0 )); then
        info 'No accounts found.'
        return 0
    fi
    local label
    for label in "${USER_LABELS[@]}"; do printf '    %s\n' "$label"; done
    printf '\n'
    hint "Accounts with host '%' accept connections from any IP address."
}

view_grants() {
    title 'Show grants for an account'
    nav_hint
    local rc user host i
    while true; do
        load_users
        if (( ${#USER_NAMES[@]} == 0 )); then info 'No accounts found.'; return 0; fi
        PICK_LABELS=("${USER_LABELS[@]}")
        PICK_KEYS=()
        for ((i = 0; i < ${#USER_NAMES[@]}; i++)); do PICK_KEYS+=("${USER_NAMES[i]}@${USER_HOSTS[i]}"); done
        printf '\n'
        pick_index 'Account (number or user@host):' && rc=0 || rc=$?
        if (( rc == 10 )); then return 0; fi
        user="${USER_NAMES[PICK_INDEX]}"
        host="${USER_HOSTS[PICK_INDEX]}"
        printf '\n  %sGrants for %s@%s%s\n' "$BOLD" "$user" "$host" "$RESET"
        if ! db_query -e "SHOW GRANTS FOR '$(sql_value "$user")'@'$(sql_value "$host")';" \
            | sed -E "s/(IDENTIFIED BY PASSWORD )'[^']*'/\1'<hidden>'/; s/^/    /"; then
            err 'Could not read the grants for this account.'
        fi
        hint 'Pick another account, or type back to return to the menu.'
    done
}

view_remote() {
    title 'Remote access overview'
    local -a remote_accounts=() records=() pending=()
    local account rec rec_kind rec_db rec_user rec_at rec_created rec_pre
    mapfile -t remote_accounts < <(db_query -e "SELECT User FROM mysql.user WHERE Host = '%' AND User <> '' ORDER BY User;")
    printf '  %sAccounts that accept connections from any host (live from MariaDB):%s\n' "$BOLD" "$RESET"
    if (( ${#remote_accounts[@]} == 0 )); then
        note '    none'
    else
        for account in "${remote_accounts[@]}"; do printf "    - %s@%%\n" "$account"; done
    fi

    mapfile -t records < <(active_grants)
    printf '\n  %sActive grants created by this tool:%s\n' "$BOLD" "$RESET"
    if (( ${#records[@]} == 0 )); then
        note '    none'
    else
        for rec in "${records[@]}"; do
            IFS=$'\t' read -r rec_kind rec_db rec_user rec_at rec_created rec_pre <<<"$rec"
            printf "    - %s@%% on %s (since %s, account created by tool: %s)\n" "$rec_user" "$rec_db" "$rec_at" "${rec_created:-YES}"
        done
    fi

    mapfile -t pending < <(pending_operations)
    if (( ${#pending[@]} > 0 )); then
        printf '\n  %sOperations needing attention (interrupted before completion):%s\n' "$BOLD" "$RESET"
        for rec in "${pending[@]}"; do
            IFS=$'\t' read -r rec_kind rec_db rec_user rec_at rec_created rec_pre <<<"$rec"
            printf "    - %s@%% on %s (started %s)\n" "$rec_user" "$rec_db" "$rec_at"
        done
        warn "MariaDB may hold a partial grant for these. Use 'revoke' to inspect them."
    fi
    printf '\n'
    hint 'Remote accounts that are not listed as created by this tool are never modified or removed.'
    hint 'This tool only manages the MariaDB side. Network listening and firewall rules are separate (see: diagnose).'
}

view_server() {
    title 'Server information'
    local name value
    while IFS=$'\t' read -r name value; do
        printf '    %-20s %s\n' "$name" "$value"
    done < <(db_query -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('version', 'hostname', 'port', 'bind_address', 'skip_networking', 'socket', 'datadir');")
    printf '\n'
    hint "Run '${SCRIPT_NAME} diagnose' to check whether remote connections can reach this server."
}

# ------------------------------------------------------ network diagnosis ---
# Read-only. Never changes the MariaDB configuration, the service or the firewall.
network_verdict() {
    local port skip bind addr host loopback=0 public=0 shown=''
    local -a addrs=()
    port="$(show_var port)"; skip="$(show_var skip_networking)"; bind="$(show_var bind_address)"
    printf '\n  %sNetwork exposure (read-only check)%s\n' "$BOLD" "$RESET"
    printf '    %-20s %s\n' 'port' "${port:-unknown}"
    printf '    %-20s %s\n' 'bind_address' "${bind:-not exposed by this version}"
    printf '    %-20s %s\n' 'skip_networking' "${skip:-unknown}"

    if [[ "${skip^^}" == 'ON' ]]; then
        warn 'skip_networking is ON: MariaDB accepts no TCP connection at all.'
    fi
    if [[ -n "$port" ]] && command -v ss >/dev/null 2>&1; then
        mapfile -t addrs < <(ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 { print $4 }')
    fi
    if (( ${#addrs[@]} == 0 )) && [[ -n "$bind" ]]; then
        addrs=("${bind}:${port}")
    fi
    if (( ${#addrs[@]} == 0 )); then
        info 'Could not determine which address MariaDB listens on.'
    else
        for addr in "${addrs[@]}"; do
            host="${addr%:*}"
            shown+="${addr} "
            case "$host" in
                127.*|'[::1]'|::1|localhost) loopback=1 ;;
                *) public=1 ;;
            esac
        done
        printf '    %-20s %s\n' 'listening on' "$shown"
        if (( public == 0 && loopback == 1 )); then
            warn "MariaDB listens only on the loopback interface. Remote connections CANNOT work, even with a valid grant."
            note "To accept remote connections you must set bind-address in the MariaDB configuration"
            note "and restart the service, then restrict port ${port:-3306} with your firewall."
        else
            ok "MariaDB listens on a non-loopback address. Make sure your firewall only allows trusted sources."
        fi
    fi
    hint 'This tool never changes bind-address, the service or the firewall.'
}

diagnose_flow() {
    title 'Remote connection diagnosis'
    info "MariaDB version: $(show_var version)"
    network_verdict
    local config
    config="$(grep -rHnE '^[[:space:]]*bind[-_]address' /etc/mysql /etc/my.cnf /etc/my.cnf.d 2>/dev/null || true)"
    if [[ -n "$config" ]]; then
        printf '\n  %sbind-address settings found in configuration files:%s\n' "$BOLD" "$RESET"
        sed 's/^/    /' <<<"$config"
    fi
    local remote_count
    remote_count="$(db_query -e "SELECT COUNT(*) FROM mysql.user WHERE Host = '%' AND User <> '';")" || remote_count='?'
    printf '\n'
    info "Accounts allowed from any host: ${remote_count}"
    hint 'A grant is only half of remote access: the server must also listen on a reachable address.'
}

# ------------------------------------------------------------ grant flow ----
grant_flow() {
    local step=0 rc
    local database='' username='' account_created='YES'
    local user_sql db_id remote_exists broad_rc existing_privs verified
    local password='' password_confirm='' confirmation sql
    local -a local_users=()

    title 'Grant remote access to one database'
    nav_hint

    while true; do
        case "$step" in
        0)  printf '\n  %sStep 1/4 - Choose the database%s\n' "$BOLD" "$RESET"
            load_databases
            if (( ${#DB_NAMES[@]} == 0 )); then warn 'No user databases found.'; return 0; fi
            PICK_LABELS=("${DB_LABELS[@]}"); PICK_KEYS=("${DB_NAMES[@]}")
            printf '\n'
            pick_index 'Database (number or name):' && rc=0 || rc=$?
            if (( rc == 10 )); then return 0; fi
            database="${DB_NAMES[PICK_INDEX]}"
            step=1
            ;;
        1)  printf '\n  %sStep 2/4 - Choose the existing localhost account%s\n' "$BOLD" "$RESET"
            note "The remote account will use the same username as an account that already exists as ${BOLD}user@localhost${RESET}."
            local_users=()
            mapfile -t local_users < <(db_query -e "SELECT DISTINCT User FROM mysql.user WHERE Host = 'localhost' AND User NOT IN ('', 'root', 'mariadb.sys', 'mysql') ORDER BY User;")
            if (( ${#local_users[@]} == 0 )); then
                warn 'No eligible localhost accounts found (root and system accounts are excluded).'
                step=0; continue
            fi
            PICK_LABELS=("${local_users[@]}"); PICK_KEYS=("${local_users[@]}")
            printf '\n'
            pick_index 'Username (number or name):' && rc=0 || rc=$?
            if (( rc == 10 )); then step=0; continue; fi
            username="${local_users[PICK_INDEX]}"

            remote_exists="$(remote_account_count "$username")" \
                || { err 'Could not check for an existing remote account.'; continue; }
            account_created='YES'
            if [[ "$remote_exists" == '1' ]]; then
                account_created='NO'
                has_broad_grants "$username" && broad_rc=0 || broad_rc=$?
                if (( broad_rc == 2 )); then err 'Could not inspect the existing remote account.'; continue; fi
                if (( broad_rc == 0 )); then
                    warn "${username}@'%' has global or role-based grants. It is left untouched."
                    warn 'Choose another account or type back.'
                    continue
                fi
                existing_privs="$(count_db_privileges "$username" "$database")" \
                    || { err 'Could not inspect the existing privileges.'; continue; }
                if [[ "$existing_privs" != '0' ]]; then
                    warn "${username}@'%' already has privileges that cover ${database} (database, table, column or routine level)."
                    warn 'An existing remote account with access to this database is never modified:'
                    warn 'the tool could not tell later which privileges were its own. Nothing was changed.'
                    continue
                fi
                info "${username}@'%' already exists with no privileges on ${database}. It will be reused; its password will NOT change."
                step=4
            else
                step=2
            fi
            ;;
        2)  printf '\n  %sStep 3/4 - Password for the new remote account%s\n' "$BOLD" "$RESET"
            note "You change ${BOLD}nothing${RESET} in your application. It keeps the same host, the same username and the same password."
            note "MariaDB treats ${username}@localhost and ${username}@'%' as two different accounts."
            note "This tool adds the second one (${username}@'%') so that remote connections are accepted."
            printf '\n'
            warn "When asked, enter the SAME password that is already configured in your application."
            hint "Input is hidden. Type :back to go back or :quit to exit."
            printf '\n'
            ask password 'Password:' secret && rc=0 || rc=$?
            if (( rc == 10 )); then password=''; step=1; continue; fi
            if [[ -z "$password" ]]; then err 'Password cannot be empty.'; continue; fi
            step=3
            ;;
        3)  ask password_confirm 'Confirm password:' secret && rc=0 || rc=$?
            if (( rc == 10 )); then password=''; password_confirm=''; step=2; continue; fi
            if [[ "$password" != "$password_confirm" ]]; then
                err 'Passwords do not match. Please enter them again.'
                password=''; password_confirm=''; step=2; continue
            fi
            password_confirm=''
            step=4
            ;;
        4)  printf '\n  %sStep 4/4 - Review and confirm%s\n\n' "$BOLD" "$RESET"
            printf '    %-18s %s\n' 'Database:' "$database"
            if [[ "$account_created" == 'YES' ]]; then
                printf "    %-18s %s\n" 'Remote account:' "${username}@'%' (will be created)"
            else
                printf "    %-18s %s\n" 'Remote account:' "${username}@'%' (already exists, password unchanged)"
            fi
            printf '    %-18s %s\n' 'Allowed from:' 'any source IP address'
            printf '    %-18s %s\n' 'Privileges:' "ALL PRIVILEGES on ${database} only (this exact name, no wildcard)"
            printf "    %-18s %s\n" 'Not affected:' "${username}@localhost and every other database"
            printf '\n'
            note 'Your application does not need any change (same host, username and password).'
            note 'Network listening (bind-address) and the firewall are NOT changed by this tool.'
            printf '\n'
            ask confirmation "Type GRANT to apply (or 'back'):" && rc=0 || rc=$?
            if (( rc == 10 )); then
                if [[ "$account_created" == 'YES' ]]; then step=2; else step=1; fi
                password=''; continue
            fi
            if [[ "$confirmation" != 'GRANT' ]]; then
                warn "Nothing applied. Type GRANT exactly to confirm, or 'back' to change something."
                continue
            fi
            step=5
            ;;
        5)  user_sql="$(sql_value "$username")"
            db_id="$(grant_identifier "$database")"
            # 1. Write-ahead record: if the history cannot be written, MariaDB is not touched.
            if ! history_append PENDING "$database" "$username" "$(date -Is)" "$account_created" 'NONE'; then
                password=''
                err "Cannot write the history file (${HISTORY_FILE}). Nothing was changed in MariaDB."
                return 1
            fi
            # 2. Apply the grant. Any failure or interruption from here on is rolled back.
            if [[ "$account_created" == 'YES' ]]; then
                INFLIGHT_KIND='create'
                sql="CREATE USER '${user_sql}'@'%' IDENTIFIED BY '$(sql_value "$password")'; GRANT ALL PRIVILEGES ON ${db_id}.* TO '${user_sql}'@'%';"
            else
                INFLIGHT_KIND='reuse'
                sql="GRANT ALL PRIVILEGES ON ${db_id}.* TO '${user_sql}'@'%';"
            fi
            INFLIGHT_USER="$username"; INFLIGHT_DB="$database"
            password=''
            if ! printf '%s\n' "$sql" | db_query; then
                sql=''
                err 'MariaDB rejected the request.'
                rollback_inflight || true
                return 1
            fi
            sql=''
            # 3. Verify that MariaDB really holds the grant.
            verified="$(count_db_privileges "$username" "$database")" || verified='0'
            if [[ "$verified" == '0' ]]; then
                err 'MariaDB reported success, but the grant is not visible. Rolling back.'
                rollback_inflight || true
                return 1
            fi
            # 4. Record it. If that fails, no untracked access is left behind.
            if ! history_append ACTIVE "$database" "$username" "$(date -Is)" "$account_created" 'NONE'; then
                err 'The grant succeeded but could not be recorded in the history file.'
                err 'Rolling back so that no untracked access remains.'
                rollback_inflight || true
                return 1
            fi
            INFLIGHT_KIND=''
            printf '\n'
            if [[ "$account_created" == 'YES' ]]; then
                ok "Created ${username}@'%' and granted it access to ${database} only."
            else
                ok "Granted the existing account ${username}@'%' access to ${database} only."
            fi
            info 'Application settings are unchanged: same host, same username, same password.'
            info "History: ${HISTORY_FILE}"
            network_verdict
            return 0
            ;;
        esac
    done
}

# ----------------------------------------------------------- revoke flow ----
revoke_flow() {
    local step=0 rc idx rec confirmation manual='NO'
    local rec_kind='' rec_db='' rec_user='' rec_at='' rec_created='YES' rec_pre=''
    local u_sql broad_rc other remaining account_exists dropped='NO'
    local -a records=()

    title 'Revoke remote access'
    nav_hint

    while true; do
        case "$step" in
        0)  printf '\n  %sStep 1/2 - Choose the grant to revoke%s\n' "$BOLD" "$RESET"
            mapfile -t records < <(active_grants; pending_operations)
            if (( ${#records[@]} == 0 )); then
                info 'No active remote grants created by this tool.'
                hint 'Remote accounts that are not tracked in the history are never modified or removed.'
                return 0
            fi
            PICK_LABELS=(); PICK_KEYS=()
            for rec in "${records[@]}"; do
                IFS=$'\t' read -r rec_kind rec_db rec_user rec_at rec_created rec_pre <<<"$rec"
                rec_at="${rec_at:-?}"
                if [[ "$rec_kind" == 'PENDING' ]]; then
                    PICK_LABELS+=("$(printf "%-30s on %-28s since %s [interrupted]" "${rec_user}@%" "$rec_db" "$rec_at")")
                else
                    PICK_LABELS+=("$(printf "%-30s on %-28s since %s" "${rec_user}@%" "$rec_db" "$rec_at")")
                fi
                PICK_KEYS+=("${rec_user}@%")
            done
            printf '\n'
            pick_index 'Grant (number or user@%):' && rc=0 || rc=$?
            if (( rc == 10 )); then return 0; fi
            idx=$PICK_INDEX
            rec_created='YES'; rec_pre=''
            IFS=$'\t' read -r rec_kind rec_db rec_user rec_at rec_created rec_pre <<<"${records[idx]}"
            rec_created="${rec_created:-YES}"
            manual='NO'
            if [[ "$rec_kind" == 'PENDING' || ( "$rec_created" == 'NO' && "$rec_pre" != 'NONE' ) ]]; then
                manual='YES'
            fi
            step=1
            ;;
        1)  printf '\n  %sStep 2/2 - Confirm%s\n\n' "$BOLD" "$RESET"
            if [[ "$manual" == 'YES' ]]; then
                if [[ "$rec_kind" == 'PENDING' ]]; then
                    warn 'This operation was interrupted. MariaDB may hold a partial or complete grant.'
                else
                    warn 'This record comes from an older version that did not check the account'
                    warn 'for pre-existing privileges. Automatic revocation is disabled so that'
                    warn 'privileges this tool did not add are never removed.'
                fi
                printf '\n  %sCurrent grants of %s@%%:%s\n' "$BOLD" "$rec_user" "$RESET"
                db_query -e "SHOW GRANTS FOR '$(sql_value "$rec_user")'@'%';" 2>/dev/null \
                    | sed -E "s/(IDENTIFIED BY PASSWORD )'[^']*'/\1'<hidden>'/; s/^/    /" \
                    || note '    (account not found)'
                printf '\n'
                note 'If you are sure every privilege on this database was added by this tool, you can run:'
                printf "    REVOKE ALL PRIVILEGES ON \`<database as shown above>\`.* FROM '%s'@'%%';\n\n" "$rec_user"
                ask confirmation "Type FORGET to drop this history record only (MariaDB is NOT changed), or 'back':" && rc=0 || rc=$?
                if (( rc == 10 )); then step=0; continue; fi
                if [[ "$confirmation" != 'FORGET' ]]; then
                    warn "Nothing changed. Type FORGET exactly, or 'back'."
                    continue
                fi
                if [[ "$rec_kind" == 'PENDING' ]]; then
                    history_append ABORTED "$rec_db" "$rec_user" "$(date -Is)" 'closed manually' || { err 'Could not write the history file.'; return 1; }
                else
                    history_append REVOKED "$rec_db" "$rec_user" "$(date -Is)" || { err 'Could not write the history file.'; return 1; }
                fi
                ok 'Record removed from the history. MariaDB was not changed.'
                warn "${rec_user}@'%' keeps whatever privileges it has until you revoke them yourself."
                return 0
            fi
            if [[ "$rec_created" == 'YES' ]]; then
                note "This will DROP the remote account ${rec_user}@'%' that this tool created."
                note "If it has gained other privileges since, it is kept and only its privileges on ${rec_db} are revoked."
            else
                note "This will revoke the privileges of ${rec_user}@'%' on ${rec_db} only."
                note 'The account itself existed before and is kept. Before the grant, this tool verified'
                note 'that it had no privileges on this database, so only what was added is removed.'
            fi
            note "The localhost account ${rec_user}@localhost is not touched."
            warn 'Remote applications using this account will stop connecting.'
            printf '\n'
            ask confirmation "Type REVOKE to apply (or 'back'):" && rc=0 || rc=$?
            if (( rc == 10 )); then step=0; continue; fi
            if [[ "$confirmation" != 'REVOKE' ]]; then
                warn "Nothing applied. Type REVOKE exactly to confirm, or 'back' to choose another grant."
                continue
            fi
            step=2
            ;;
        2)  u_sql="$(sql_value "$rec_user")"
            dropped='NO'
            account_exists="$(remote_account_count "$rec_user")" \
                || { err 'Could not check the remote account.'; step=1; continue; }
            if [[ "$account_exists" == '1' ]]; then
                if [[ "$rec_created" == 'YES' ]]; then
                    has_broad_grants "$rec_user" && broad_rc=0 || broad_rc=$?
                    other="$(count_other_privileges "$rec_user" "$rec_db")" || other='unknown'
                    if (( broad_rc == 1 )) && [[ "$other" == '0' ]]; then
                        if ! db_query -e "DROP USER '${u_sql}'@'%';"; then
                            err 'MariaDB could not drop the remote account.'; step=1; continue
                        fi
                        dropped='YES'
                    else
                        warn "${rec_user}@'%' holds other privileges now. It is NOT dropped; only its privileges on ${rec_db} are revoked."
                        if ! revoke_db_rows "$rec_user" "$rec_db"; then
                            err 'MariaDB could not revoke the database privileges.'; step=1; continue
                        fi
                    fi
                else
                    if ! revoke_db_rows "$rec_user" "$rec_db"; then
                        err 'MariaDB could not revoke the database privileges.'; step=1; continue
                    fi
                fi
                # Verify that the exact database-level grant(s) managed by this
                # tool are gone. Other grants may still cover the same schema.
                if [[ "$dropped" == 'YES' ]]; then
                    remaining="$(remote_account_count "$rec_user")" || remaining='?'
                else
                    remaining="$(count_exact_db_rows "$rec_user" "$rec_db")" || remaining='?'
                fi
                if [[ "$remaining" != '0' ]]; then
                    err "MariaDB still shows the exact database grant for ${rec_user}@'%' on ${rec_db}. The history was NOT updated."
                    step=1; continue
                fi
            else
                warn 'The remote account no longer exists in MariaDB. Cleaning up the history only.'
            fi
            if ! history_append REVOKED "$rec_db" "$rec_user" "$(date -Is)"; then
                err "MariaDB was updated, but the history file could not be written (${HISTORY_FILE})."
                err 'The grant is already gone; the history still lists it as active.'
                return 1
            fi
            printf '\n'
            if [[ "$dropped" == 'YES' ]]; then
                ok "Dropped ${rec_user}@'%'. The localhost account remains unchanged."
            else
                ok "Revoked ${rec_user}@'%' on ${rec_db}. The localhost account remains unchanged."
                if [[ "$rec_created" == 'YES' ]]; then
                    info "The remote account was kept because it has privileges beyond the grant managed here."
                fi
            fi
            return 0
            ;;
        esac
    done
}

# --------------------------------------------------------- legacy history ---
migrate_flow() {
    local i rc confirmation kind db user at created pre
    local -a fields=()
    title 'Import a legacy history file'
    nav_hint
    collect_legacy
    if (( ${#LEGACY_LINES[@]} == 0 )); then
        info 'No legacy history records to import.'
        return 0
    fi
    printf '\n'
    for ((i = 0; i < ${#LEGACY_LINES[@]}; i++)); do
        IFS=$'\t' read -r kind db user at created pre <<<"${LEGACY_LINES[i]}"
        printf '    %-8s %s@%% on %s (%s)  [%s]\n' "$kind" "$user" "$db" "$at" "$(basename -- "${LEGACY_FILES[i]}")"
    done
    printf '\n'
    note 'Importing only copies these records into the current history file.'
    note 'Nothing is revoked, dropped or changed in MariaDB.'
    note 'Reused-account entries from older versions stay "legacy": they are never revoked automatically.'
    printf '\n'
    while true; do
        ask confirmation "Type IMPORT to copy ${#LEGACY_LINES[@]} record(s) (or 'back'):" && rc=0 || rc=$?
        if (( rc == 10 )); then return 0; fi
        [[ "$confirmation" == 'IMPORT' ]] && break
        warn "Nothing imported. Type IMPORT exactly, or 'back'."
    done
    for ((i = 0; i < ${#LEGACY_LINES[@]}; i++)); do
        IFS=$'\t' read -r -a fields <<<"${LEGACY_LINES[i]}"
        if ! history_append "${fields[@]}"; then
            err "Could not write ${HISTORY_FILE}. Import stopped after ${i} record(s)."
            return 1
        fi
    done
    ok "Imported ${#LEGACY_LINES[@]} record(s) into ${HISTORY_FILE}."
}

startup_notices() {
    local -a pending=()
    local rec rec_kind rec_db rec_user rec_at rec_rest
    mapfile -t pending < <(pending_operations)
    for rec in "${pending[@]}"; do
        [[ -n "$rec" ]] || continue
        IFS=$'\t' read -r rec_kind rec_db rec_user rec_at rec_rest <<<"$rec"
        warn "Interrupted operation found: ${rec_user}@'%' on ${rec_db} (started ${rec_at}). Use 'Revoke remote access' to inspect it."
    done
    collect_legacy
    if (( ${#LEGACY_LINES[@]} > 0 )); then
        warn "Legacy history found ($(basename -- "${LEGACY_FILES[0]}")) with ${#LEGACY_LINES[@]} record(s) not in the current history."
        warn "It is NOT read automatically. Use 'Import legacy history' to review it. Nothing is ever revoked because a history is missing."
    fi
}

# ------------------------------------------------------------------ menu ----
main_menu() {
    local choice rc
    startup_notices
    while true; do
        title "MariaDB Manager ${VERSION}"
        printf '    %s1)%s List databases\n' "$CYAN" "$RESET"
        printf '    %s2)%s List accounts\n' "$CYAN" "$RESET"
        printf '    %s3)%s Show grants for an account\n' "$CYAN" "$RESET"
        printf '    %s4)%s Remote access overview\n' "$CYAN" "$RESET"
        printf '    %s5)%s Grant remote access to one database\n' "$CYAN" "$RESET"
        printf '    %s6)%s Revoke remote access\n' "$CYAN" "$RESET"
        printf '    %s7)%s Server information\n' "$CYAN" "$RESET"
        printf '    %s8)%s Network diagnosis (can remote clients connect?)\n' "$CYAN" "$RESET"
        printf '    %s9)%s Import legacy history\n' "$CYAN" "$RESET"
        printf '    %sq)%s Quit\n\n' "$CYAN" "$RESET"
        ask choice 'Choice:' && rc=0 || rc=$?
        if (( rc == 10 )); then hint "You are already at the main menu. Type 'quit' to exit."; continue; fi
        case "$choice" in
            1) view_databases ;;
            2) view_users ;;
            3) view_grants ;;
            4) view_remote ;;
            5) grant_flow || true ;;
            6) revoke_flow || true ;;
            7) view_server ;;
            8) diagnose_flow ;;
            9) migrate_flow || true ;;
            *) err "Invalid choice: ${choice}" ;;
        esac
    done
}

case "$COMMAND" in
    menu)      main_menu ;;
    databases) view_databases ;;
    users)     view_users ;;
    remote)    view_remote ;;
    info)      view_server ;;
    diagnose)  diagnose_flow ;;
    grant)     grant_flow ;;
    revoke)    revoke_flow ;;
    migrate)   migrate_flow ;;
esac
