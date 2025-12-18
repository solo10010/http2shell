#!/bin/bash

############################
# DEFAULT SETTINGS
############################
LISTEN_IP="127.0.0.1"
PORT="8007"

AUTH_USER="rest"
AUTH_PASS="api"

ALLOW_EXEC=1
CUSTOM_ENDPOINTS=""
NO_COLOR=0
EXEC_SHELL=""

# Timeouts
CMD_TIMEOUT=20      # seconds for xcmd execution
BODY_TIMEOUT=10     # seconds for reading request body

############################
# COLORS (can be disabled)
############################
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

############################
# HELP
############################
show_help() {
cat <<EOF
Bash API Server (socat)

Usage:
  $0 [options]

Options:
  -h, --help
        Show this help

  -ip, --ip <ip>
        Listen IP (default: 127.0.0.1)

  -port, --port <port>
        Listen port (default: 8007)

  -u, --user <user>
        Basic auth user (default: rest)

  -p, --pass <pass>
        Basic auth password (default: api)

  -s, --shell <path>
        Shell for command execution

  --no-exec
        Disable /exec and /execf endpoints

  -e, --endpoint <uri> <command>
        Add custom POST endpoint

  --no-color
        Disable colored output

  --cmd-timeout <sec>
        Timeout for xcmd execution (default: 20)

  --body-timeout <sec>
        Timeout for reading request body (default: 10)
EOF
exit 0
}

############################
# ARGUMENTS
############################
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        -ip|--ip) LISTEN_IP="$2"; shift 2 ;;
        -port|--port) PORT="$2"; shift 2 ;;
        -u|--user) AUTH_USER="$2"; shift 2 ;;
        -p|--pass) AUTH_PASS="$2"; shift 2 ;;
        -s|--shell) EXEC_SHELL="$2"; shift 2 ;;
        --no-exec) ALLOW_EXEC=0; shift ;;
        --no-color) NO_COLOR=1; shift ;;
        --cmd-timeout) CMD_TIMEOUT="$2"; shift 2 ;;
        --body-timeout) BODY_TIMEOUT="$2"; shift 2 ;;
        -e|--endpoint)
            URI="$2"
            CMD="$3"
            [ -z "$URI" ] || [ -z "$CMD" ] && {
                echo "[ERROR] --endpoint requires <uri> <command>" >&2
                exit 1
            }
            CUSTOM_ENDPOINTS+="${URI}=${CMD};"
            shift 3
            ;;
        *)
            echo "[ERROR] Unknown argument: $1" >&2
            echo "Use -h or --help" >&2
            exit 1
            ;;
    esac
done

############################
# SHELL AUTODETECT
############################
if [ -n "$EXEC_SHELL" ]; then
    :
elif [ -n "$SHELL" ] && [ -x "$SHELL" ]; then
    EXEC_SHELL="$SHELL"
elif [ -x /bin/bash ]; then
    EXEC_SHELL="/bin/bash"
elif [ -x /bin/sh ]; then
    EXEC_SHELL="/bin/sh"
else
    echo "[ERROR] No usable shell found" >&2
    exit 1
fi

############################
# DISABLE COLORS IF NEEDED
############################
if [ "$NO_COLOR" -eq 1 ]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

############################
# CHECKS
############################
command -v socat >/dev/null 2>&1 || { echo "${RED}[ERROR]${RESET} socat not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "${RED}[ERROR]${RESET} jq not found" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "${RED}[ERROR]${RESET} sha256sum not found" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "${RED}[ERROR]${RESET} timeout not found" >&2; exit 1; }
command -v dd >/dev/null 2>&1 || { echo "${RED}[ERROR]${RESET} dd not found" >&2; exit 1; }

export SERVER_TOKEN
SERVER_TOKEN=$(echo -n "$AUTH_USER:$AUTH_PASS" | base64)

export ALLOW_EXEC CUSTOM_ENDPOINTS NO_COLOR EXEC_SHELL SERVER_TOKEN CMD_TIMEOUT BODY_TIMEOUT

############################
# START LOG
############################
printf "%b\n" "${BLUE}[INFO]${RESET} ===== Bash API Server =====" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Listening on: $LISTEN_IP:$PORT" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Auth: $AUTH_USER / $AUTH_PASS" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Exec enabled: $([ "$ALLOW_EXEC" -eq 1 ] && echo YES || echo NO)" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Exec shell: $EXEC_SHELL" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} CMD timeout: ${CMD_TIMEOUT}s | BODY timeout: ${BODY_TIMEOUT}s" >&2
[ -n "$CUSTOM_ENDPOINTS" ] && printf "%b\n" "${BLUE}[INFO]${RESET} Custom endpoints: $CUSTOM_ENDPOINTS" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Started at: $(date)" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} ============================" >&2

############################
# HANDLER
############################
HANDLER=$(mktemp)

cat > "$HANDLER" <<'EOF'
#!/bin/bash

if [ "$NO_COLOR" = "1" ]; then
    C_INFO=""; C_WARN=""; C_EXEC=""; C_RESET=""
else
    C_INFO="\033[34m"
    C_WARN="\033[33m"
    C_EXEC="\033[32m"
    C_RESET="\033[0m"
fi

log()      { echo -e "${C_INFO}[INFO]${C_RESET} $*" >&2; }
warn()     { echo -e "${C_WARN}[WARN]${C_RESET} $*" >&2; }
exec_log() { echo -e "${C_EXEC}[EXEC]${C_RESET} $*" >&2; }

http_reply() {
    local code="$1" msg="$2" type="$3" body="$4"
    local len
    len=$(printf "%s" "$body" | wc -c)
    printf "HTTP/1.1 %s %s\r\nConnection: close\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s" \
        "$code" "$msg" "$type" "$len" "$body"
}

json_error() {
    local http="$1" msg="$2" detail="$3"
    http_reply "$http" "$msg" "application/json" \
      "$(jq -cn --arg error "$msg" --arg detail "$detail" --argjson code "$http" '{error:$error, detail:$detail, code:$code}')"
}

# Read request line (avoid hanging forever)
read -r -t 5 REQUEST_LINE || exit 0
METHOD=$(awk '{print $1}' <<< "$REQUEST_LINE")
URI=$(awk '{print $2}' <<< "$REQUEST_LINE")

CLIENT_IP=${SOCAT_PEERADDR:-unknown}
AUTH=""
CLEN=0
XCMD=""

# Read headers with timeout
while read -r -t 5 HEADER; do
    HEADER="${HEADER%$'\r'}"
    [ -z "$HEADER" ] && break
    case "$HEADER" in
        Content-Length:*) CLEN=${HEADER#*: } ;;
        Authorization:*)  AUTH=${HEADER#Authorization: } ;;
        Xcmd:*|xcmd:*)    XCMD=${HEADER#*: } ;;
    esac
done

log "$(date) $CLIENT_IP $METHOD $URI"

# Auth
if [ "$AUTH" != "Basic $SERVER_TOKEN" ]; then
    warn "AUTH FAILED from $CLIENT_IP"
    json_error 401 "Unauthorized" "Bad or missing Authorization header"
    exit 0
fi

# Read body EXACT bytes, with timeout
POST_DATA=""
if [ "$METHOD" = "POST" ] && [ "$CLEN" -gt 0 ]; then
    POST_DATA=$(timeout "${BODY_TIMEOUT:-10}" dd bs=1 count="$CLEN" 2>/dev/null)
    RC=$?
    if [ $RC -eq 124 ]; then
        json_error 408 "Request Timeout" "Body read timeout"
        exit 0
    elif [ $RC -ne 0 ]; then
        json_error 400 "Bad Request" "Failed to read request body"
        exit 0
    fi
fi

START=$(date +%s%3N)

run_cmd_timeout() {
    # run command with timeout, capture stdout+stderr
    timeout "${CMD_TIMEOUT:-20}" "$EXEC_SHELL" -c "$1" 2>&1
}

case "$URI" in
    "/api/uptime")
        BODY=$(uptime -p)
        TYPE="text/plain"
        http_reply 200 "OK" "$TYPE" "$BODY"
        ;;
    "/api/disk")
        BODY=$(lsblk -e7 -f --json)
        TYPE="application/json"
        http_reply 200 "OK" "$TYPE" "$BODY"
        ;;

    "/execf")
        [ "$ALLOW_EXEC" -ne 1 ] && { json_error 403 "Forbidden" "Exec disabled"; exit 0; }
        [ -z "$XCMD" ] && { json_error 400 "Bad Request" "Missing xcmd header"; exit 0; }

        # Hash based on body bytes
        HASH=$(printf "%s" "$POST_DATA" | sha256sum | awk '{print $1}')
        textfile="/tmp/http2shell-$HASH.txt"

        # Write lines:
        # 1) If body is ["a","b"] -> write exactly those
        # 2) Else extract any strings that are elements of any arrays in JSON
        if echo "$POST_DATA" | jq -e 'type=="array" and (all(.[]; type=="string"))' >/dev/null 2>&1; then
            echo "$POST_DATA" | jq -r '.[]' > "$textfile"
        else
            # Works for: [{"linesArray":[...],...}] and also nested arrays
            echo "$POST_DATA" | jq -r '.. | arrays | .[] | select(type=="string")' > "$textfile"
        fi

        export textfile
        exec_log "$CLIENT_IP execf: $XCMD (file=$textfile)"

        OUT_FILE=$(mktemp)
        ERR_FILE=$(mktemp)

        timeout "${CMD_TIMEOUT:-20}" \
        "$EXEC_SHELL" -c "$XCMD" \
        >"$OUT_FILE" 2>"$ERR_FILE"
        RC=$?

        STDOUT=$(cat "$OUT_FILE")
        STDERR=$(cat "$ERR_FILE")

        rm -f "$OUT_FILE" "$ERR_FILE"

        if [ $RC -eq 124 ]; then
            BODY=$(jq -cn \
            --arg textfile "$textfile" \
            --arg stdout "" \
            --arg stderr "command timeout" \
            --argjson code 504 \
            '{textfile:$textfile, stdout:$stdout, stderr:$stderr, code:$code}')
            http_reply 504 "Gateway Timeout" "application/json" "$BODY"
            exit 0
        fi

        BODY=$(jq -cn \
        --arg textfile "$textfile" \
        --arg stdout "$STDOUT" \
        --arg stderr "$STDERR" \
        --argjson code "$RC" \
        '{textfile:$textfile, stdout:$stdout, stderr:$stderr, code:$code}')
        http_reply 200 "OK" "application/json" "$BODY"

        rm -f "$textfile"

        ;;

    "/exec")
        [ "$ALLOW_EXEC" -ne 1 ] && { json_error 403 "Forbidden" "Exec disabled"; exit 0; }
        OUT=$(run_cmd_timeout "$POST_DATA")
        RC=$?
        if [ $RC -eq 124 ]; then
            json_error 504 "Gateway Timeout" "command timeout"
            exit 0
        fi
        http_reply 200 "OK" "text/plain" "$OUT"
        ;;

    *)
        FOUND=0
        IFS=';' read -ra PAIRS <<< "$CUSTOM_ENDPOINTS"
        for p in "${PAIRS[@]}"; do
            [ -z "$p" ] && continue
            ep="${p%%=*}"
            cmd="${p#*=}"
            if [ "$URI" = "$ep" ]; then
                exec_log "$CLIENT_IP $URI => $cmd"
                OUT=$(run_cmd_timeout "$cmd")
                RC=$?
                if [ $RC -eq 124 ]; then
                    json_error 504 "Gateway Timeout" "command timeout"
                    exit 0
                fi
                http_reply 200 "OK" "text/plain" "$OUT"
                FOUND=1
                break
            fi
        done
        [ "$FOUND" -ne 1 ] && http_reply 404 "Not Found" "text/plain" "Not found"
        ;;
esac

END=$(date +%s%3N)
DUR=$((END-START))
log "$CLIENT_IP $METHOD $URI done in ${DUR}ms"
EOF

chmod +x "$HANDLER"

exec socat TCP4-LISTEN:$PORT,bind=$LISTEN_IP,reuseaddr,fork EXEC:"$HANDLER"
