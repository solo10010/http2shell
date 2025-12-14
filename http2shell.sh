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
        Priority:
          1) --shell
          2) \$SHELL
          3) /bin/bash
          4) /bin/sh

  --no-exec
        Disable /exec endpoint

  -e, --endpoint <uri> <command>
        Add custom POST endpoint

  --no-color
        Disable colored output
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
command -v socat >/dev/null 2>&1 || {
    echo "${RED}[ERROR]${RESET} socat not found" >&2
    exit 1
}

export SERVER_TOKEN
SERVER_TOKEN=$(echo -n "$AUTH_USER:$AUTH_PASS" | base64)
export ALLOW_EXEC CUSTOM_ENDPOINTS NO_COLOR EXEC_SHELL

############################
# START LOG
############################
printf "%b\n" "${BLUE}[INFO]${RESET} ===== Bash API Server =====" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Listening on: $LISTEN_IP:$PORT" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Auth: $AUTH_USER / $AUTH_PASS" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Exec enabled: $([ "$ALLOW_EXEC" -eq 1 ] && echo YES || echo NO)" >&2
printf "%b\n" "${BLUE}[INFO]${RESET} Exec shell: $EXEC_SHELL" >&2
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

read -r REQUEST_LINE || exit 0
METHOD=$(awk '{print $1}' <<< "$REQUEST_LINE")
URI=$(awk '{print $2}' <<< "$REQUEST_LINE")

CLIENT_IP=${SOCAT_PEERADDR:-unknown}
AUTH=""
CLEN=0

while read -r HEADER; do
    HEADER="${HEADER%$'\r'}"
    [ -z "$HEADER" ] && break
    case "$HEADER" in
        Content-Length:*) CLEN=${HEADER#*: } ;;
        Authorization:*) AUTH=${HEADER#Authorization: } ;;
    esac
done

log "$(date) $CLIENT_IP $METHOD $URI"

if [ "$AUTH" != "Basic $SERVER_TOKEN" ]; then
    BODY="401 Unauthorized"
    printf "HTTP/1.1 401 Unauthorized\r\nContent-Length: %d\r\n\r\n%s" "${#BODY}" "$BODY"
    warn "AUTH FAILED from $CLIENT_IP"
    exit 0
fi

POST_DATA=""
[ "$METHOD" = "POST" ] && [ "$CLEN" -gt 0 ] && read -n "$CLEN" POST_DATA

START=$(date +%s%3N)

run_cmd() {
    "$EXEC_SHELL" -c "$1" 2>&1
}

case "$URI" in
    "/api/uptime")
        BODY=$(uptime -p)
        TYPE="text/plain"
        ;;
    "/api/disk")
        BODY=$(lsblk -e7 -f --json)
        TYPE="application/json"
        ;;
    "/exec")
        [ "$ALLOW_EXEC" -ne 1 ] && {
            BODY="403 Forbidden"
            printf "HTTP/1.1 403 Forbidden\r\nContent-Length: %d\r\n\r\n%s" "${#BODY}" "$BODY"
            warn "EXEC BLOCKED"
            exit 0
        }
        exec_log "$CLIENT_IP exec: $POST_DATA"
        BODY=$(run_cmd "$POST_DATA")
        TYPE="text/plain"
        ;;
    *)
        FOUND=0
        IFS=';' read -ra PAIRS <<< "$CUSTOM_ENDPOINTS"
        for p in "${PAIRS[@]}"; do
            ep="${p%%=*}"
            cmd="${p#*=}"
            if [ "$URI" = "$ep" ]; then
                exec_log "$CLIENT_IP $URI => $cmd"
                BODY=$(run_cmd "$cmd")
                TYPE="text/plain"
                FOUND=1
                break
            fi
        done
        [ "$FOUND" -ne 1 ] && BODY="Not found" && TYPE="text/plain"
        ;;
esac

END=$(date +%s%3N)
DUR=$((END-START))

LEN=$(printf "%s" "$BODY" | wc -c)
printf "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n%s" "$TYPE" "$LEN" "$BODY"

log "$CLIENT_IP $METHOD $URI done in ${DUR}ms"
EOF

chmod +x "$HANDLER"

exec socat TCP4-LISTEN:$PORT,bind=$LISTEN_IP,reuseaddr,fork EXEC:"$HANDLER"
