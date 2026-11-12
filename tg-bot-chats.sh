#!/bin/sh
# tg-bot-chats.sh — liệt kê chat/group/channel mà bot Telegram đang tham gia.
#
# Telegram KHÔNG có endpoint liệt kê đầy đủ chat của bot (Bot API không có
# getChats, còn MTProto với bot token bị chặn messages.getDialogs). Script này
# khai thác tối đa những gì lấy được:
#
#   1. getUpdates -> mọi chat xuất hiện trong update (giới hạn ~24h, cần bot
#      không đặt webhook). Không confirm update nào ở chế độ một lần.
#   2. getChat / getChatMemberCount / getChatMember -> chi tiết + trạng thái bot.
#   3. Cache vào ~/.local/share/tg-bot-chats/<bot_id>/chats/*.json để lần sau
#      vẫn thấy chat cũ dù Telegram đã hết update.
#   4. --watch -> long-poll liên tục, gom dần chat mới.
#   5. --check / --check-file -> xác minh chat_id hoặc @username đã biết.
#
# Phụ thuộc: curl, jq, find, awk (đều có sẵn trên máy này).
#
# Dùng:
#   ./tg-bot-chats.sh                        # hỏi token (ẩn ký tự)
#   ./tg-bot-chats.sh --token 123456:ABC...
#   TELEGRAM_BOT_TOKEN=... ./tg-bot-chats.sh --all
#   ./tg-bot-chats.sh --watch
#   ./tg-bot-chats.sh --check -1001234567890 --check @mygroup
#
# Biến môi trường:
#   TELEGRAM_BOT_TOKEN  token mặc định
#   TG_API_BASE         mặc định https://api.telegram.org (đổi được nếu dùng
#                       Bot API server tự host)

set -u

API_ROOT=${TG_API_BASE:-https://api.telegram.org}

ALL=0
JSON=0
WATCH=0
POLL=25
DELWH=0
NOCACHE=0
CHECKS=""
CHECKFILE=""
TOKEN=${TELEGRAM_BOT_TOKEN:-}

usage() {
	cat <<'EOF'
Dùng: tg-bot-chats.sh [tuỳ chọn]

  --token TOKEN         bot token (mặc định: $TELEGRAM_BOT_TOKEN, không có thì hỏi)
  --all                 hiện cả chat riêng tư (mặc định ẩn)
  --json                xuất JSON
  --watch               long-poll để gom chat mới (Ctrl-C dừng)
  --poll-timeout GIÂY  timeout long-poll, mặc định 25
  --delete-webhook      xoá webhook để getUpdates chạy được (GIÁN ĐOẠN bot)
  --check ID|@user      xác minh chat đã biết (lặp lại được)
  --check-file PATH     file mỗi dòng một chat_id/@username
  --no-cache            không đọc/ghi cache cục bộ
  -h, --help            trợ giúp
EOF
}

# ---------------------------------------------------------------- tham số ----
while [ $# -gt 0 ]; do
	case $1 in
	--token) TOKEN=$2; shift 2 ;;
	--token=*) TOKEN=${1#*=}; shift ;;
	--all) ALL=1; shift ;;
	--json) JSON=1; shift ;;
	--watch) WATCH=1; shift ;;
	--poll-timeout) POLL=$2; shift 2 ;;
	--delete-webhook) DELWH=1; shift ;;
	--check) CHECKS="$CHECKS $2"; shift 2 ;;
	--check-file) CHECKFILE=$2; shift 2 ;;
	--no-cache) NOCACHE=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "Tham số lạ: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [ -z "$TOKEN" ]; then
	printf 'Bot token: ' >&2
	stty -echo 2>/dev/null
	read -r TOKEN
	stty echo 2>/dev/null
	printf '\n' >&2
fi
case $TOKEN in
*:*) ;;
*)
	echo "Token không hợp lệ (định dạng <bot_id>:<secret>)." >&2
	exit 1
	;;
esac

# ------------------------------------------------------------- hạ tầng ------
api() {
	_method=$1
	shift
	curl -sS -m 90 -X POST "$API_ROOT/bot$TOKEN/$_method" "$@"
}

api_ok() {
	printf '%s' "$1" | jq -e '.ok == true' >/dev/null 2>&1
}

api_desc() {
	printf '%s' "$1" | jq -r '.description // empty' 2>/dev/null
}

# Trích mọi object chat (id dạng số) từ một response bất kỳ.
extract_ids() {
	jq -r '
		.. | objects
		| select((.type? // "") as $t
			| $t == "group" or $t == "supergroup"
			  or $t == "channel" or $t == "private")
		| select(.id? | type == "number")
		| .id
	'
}

# --------------------------------------------------------------- bot --------
ME=$(api getMe)
if ! api_ok "$ME"; then
	echo "Không gọi được getMe — kiểm tra mạng hoặc token." >&2
	_desc=$(api_desc "$ME")
	[ -n "$_desc" ] && echo "  Telegram: $_desc" >&2
	exit 1
fi
BOT_ID=$(printf '%s' "$ME" | jq -r '.result.id')
BOT_USER=$(printf '%s' "$ME" | jq -r '.result.username // ""')

# -------------------------------------------------------------- cache -------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tg-bot-chats.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ "$NOCACHE" = 1 ]; then
	CACHE=$TMP/cache
else
	CACHE=$DATA_HOME/tg-bot-chats/$BOT_ID
fi
mkdir -p "$CACHE/chats" || {
	echo "Không tạo được thư mục cache: $CACHE" >&2
	exit 1
}

# ------------------------------------------------------------ webhook -------
WH=$(api getWebhookInfo)
PENDING=$(printf '%s' "$WH" | jq -r '.result.pending_update_count // 0' 2>/dev/null || echo 0)
WH_URL=$(printf '%s' "$WH" | jq -r '.result.url // ""' 2>/dev/null || echo "")

if [ -n "$WH_URL" ]; then
	if [ "$DELWH" = 1 ]; then
		if api_ok "$(api deleteWebhook)"; then
			echo "Đã xoá webhook." >&2
			WH_URL=""
		else
			echo "Xoá webhook thất bại." >&2
		fi
	else
		echo "CẢNH BÁO: bot đang đặt webhook -> getUpdates trả 409, không đọc được update." >&2
		echo "         Dùng --delete-webhook nếu chắc chắn muốn chuyển sang polling (sẽ gián đoạn bot đang chạy)." >&2
	fi
fi

# ------------------------------------------------------ resolve 1 chat -------
# resolve <chat_id|@username> [checked]
resolve() {
	_key=$1
	_checked=${2:-0}
	_safe=$(printf '%s' "$_key" | tr -c 'A-Za-z0-9._-' '_')
	_target=$CACHE/chats/$_safe.json

	_full=$(api getChat --data-urlencode "chat_id=$_key")

	if api_ok "$_full"; then
		_id=$(printf '%s' "$_full" | jq -r '.result.id')
		_type=$(printf '%s' "$_full" | jq -r '.result.type // ""')
		_title=$(printf '%s' "$_full" | jq -r '
			(.result.title // ((.result.first_name // "") + " " + (.result.last_name // "")))
			| gsub("[\\t\\r\\n]+"; " ")
			| sub("^ +"; "") | sub(" +$"; "")')
		_uname=$(printf '%s' "$_full" | jq -r '.result.username // ""')
		_members=""

		case $_type in
		group | supergroup | channel)
			_mc=$(api getChatMemberCount --data-urlencode "chat_id=$_id")
			_members=$(printf '%s' "$_mc" | jq -r 'if .ok then (.result | tostring) else "" end' 2>/dev/null)
			;;
		esac

		_st=$(api getChatMember --data-urlencode "chat_id=$_id" --data-urlencode "user_id=$BOT_ID")
		_status=$(printf '%s' "$_st" | jq -r 'if .ok then .result.status else "?" end' 2>/dev/null)
		[ -n "$_status" ] || _status="?"

		jq -n --argjson id "$_id" --arg type "$_type" --arg title "$_title" \
			--arg uname "$_uname" --arg members "$_members" --arg status "$_status" \
			--argjson checked "$_checked" '
			{id: $id, type: $type, title: $title, username: $uname,
			 members: (if $members == "" then null else ($members | tonumber) end),
			 bot_status: $status, checked: ($checked == 1)}' \
			>"$_target.$$" && mv "$_target.$$" "$_target"

		if [ "$_safe" != "$_id" ]; then
			mv "$_target" "$CACHE/chats/$_id.json"
		fi
	else
		_desc=$(api_desc "$_full")
		[ -n "$_desc" ] || _desc="không truy cập được"
		jq -n --arg key "$_key" --arg desc "$_desc" --argjson checked "$_checked" '
			{id: $key, type: null, title: "", username: "", members: null,
			 bot_status: "-", error: $desc, checked: ($checked == 1)}' \
			>"$_target.$$" && mv "$_target.$$" "$_target"
	fi
}

# --------------------------------------------------------------- show -------
show() {
	find "$CACHE/chats" -type f -name '*.json' -exec cat {} + >"$TMP/cache.jsonl" 2>/dev/null

	if [ "$JSON" = 1 ]; then
		if [ -s "$TMP/cache.jsonl" ]; then
			jq -s --argjson all "$ALL" --arg u "$BOT_USER" --argjson bid "$BOT_ID" \
				--argjson pend "$PENDING" '
				{bot: {id: $bid, username: $u}, pending_updates: $pend,
				 chats: (map(select($all == 1 or .checked == true or .type != "private")))}' \
				"$TMP/cache.jsonl"
		else
			jq -n --arg u "$BOT_USER" --argjson bid "$BOT_ID" --argjson pend "$PENDING" \
				'{bot: {id: $bid, username: $u}, pending_updates: $pend, chats: []}'
		fi
		return
	fi

	printf 'Bot: @%s (id %s)' "$BOT_USER" "$BOT_ID"
	[ "$PENDING" != 0 ] && printf '  |  %s update đang chờ' "$PENDING"
	printf '\n'

	if [ -s "$TMP/cache.jsonl" ]; then
		jq -rs --argjson all "$ALL" '
			map(select($all == 1 or .checked == true or .type != "private"))
			| sort_by((if (.type == "group" or .type == "supergroup") then 0
			           elif .type == "channel" then 1 else 2 end), (.id | tostring))
			| .[]
			| [ (.id | tostring),
			    (.type // "?"),
			    (if .members == null then "-" else (.members | tostring) end),
			    (.bot_status // "-"),
			    (if (.title // "") == "" then (.id | tostring) else .title end),
			    (.error // "") ]
			| @tsv' "$TMP/cache.jsonl" |
			awk -F '\t' '
				BEGIN {
					printf "\n%18s  %-10s  %7s  %-14s  %s\n", "chat_id", "loại", "members", "bot", "tên"
					printf "%s\n", "--------------------------------------------------------------------------"
				}
				{
					printf "%18s  %-10s  %7s  %-14s  %s", $1, $2, $3, $4, $5
					if ($6 != "") printf "  (%s)", $6
					printf "\n"
				}'
	else
		printf '\nKhông thấy chat nào từ update/cache. Xem ghi chú bên dưới.\n'
	fi

	set -- $(jq -rs --argjson all "$ALL" '
		map(select($all == 1 or .checked == true or .type != "private")) as $v
		| [ ($v | map(select(.type != null)) | length),
		    ($v | map(select(.type == "group" or .type == "supergroup")) | length),
		    ($v | map(select(.type == "channel")) | length),
		    ($v | map(select(.type == null)) | length) ] | @tsv
	' "$TMP/cache.jsonl" 2>/dev/null | awk -F '\t' '{print $1" "$2" "$3" "$4}')
	_total=${1:-0}
	_groups=${2:-0}
	_channels=${3:-0}
	_failed=${4:-0}
	_private=$(jq -rs '[.[] | select(.type == "private")] | length' "$TMP/cache.jsonl" 2>/dev/null || echo 0)

	printf '\nTổng: %s chat (%s group, %s channel' "$_total" "$_groups" "$_channels"
	[ "$_failed" -gt 0 ] && printf ', %s mục không truy cập được' "$_failed"
	[ "$ALL" = 0 ] && [ "${_private:-0}" -gt 0 ] && printf ', %s private ẩn - dùng --all' "$_private"
	printf ')\n'

	cat <<'EOF'
Nguồn: update Telegram trả về + cache cục bộ. Telegram không có API liệt kê đầy đủ:
  - chat không có hoạt động trong ~24h và chưa từng được lưu sẽ không hiện;
  - chạy --watch để gom dần, hoặc --check <chat_id|@username> nếu đã biết id.
EOF
}

# -------------------------------------------------------------- collect -----
IDS=$TMP/ids
: >"$IDS"

if [ -z "$WH_URL" ]; then
	UPD=$(api getUpdates --data-urlencode "timeout=0" --data-urlencode "limit=100")
	if api_ok "$UPD"; then
		_n=$(printf '%s' "$UPD" | jq -r '.result | length' 2>/dev/null || echo 0)
		[ "$_n" -ge 100 ] 2>/dev/null &&
			echo "Lưu ý: có thể còn update chưa đọc (giới hạn 100/lần)." >&2
		printf '%s' "$UPD" | extract_ids >>"$IDS"
	else
		_code=$(printf '%s' "$UPD" | jq -r '.error_code // 0' 2>/dev/null || echo 0)
		if [ "$_code" = 409 ]; then
			echo "409: webhook đang bật, không dùng được getUpdates." >&2
		else
			echo "getUpdates lỗi: $(api_desc "$UPD")" >&2
		fi
	fi
fi

for _key in $CHECKS; do
	printf '%s\n' "$_key" >>"$IDS"
done

if [ -n "$CHECKFILE" ]; then
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$CHECKFILE" |
		grep -v '^#' | grep -v '^$' >>"$IDS"
fi

sort -u "$IDS" -o "$IDS"

while IFS= read -r _key; do
	[ -n "$_key" ] || continue
	_checked=0
	for _c in $CHECKS; do
		[ "$_c" = "$_key" ] && _checked=1
	done
	resolve "$_key" "$_checked"
done <"$IDS"

show

if [ "$NOCACHE" = 0 ] && [ "$JSON" = 0 ]; then
	printf '\nCache: %s\n' "$CACHE" >&2
fi

# ---------------------------------------------------------------- watch -----
[ "$WATCH" = 1 ] || exit 0

trap 'printf "\nDừng.\n" >&2; exit 0' INT TERM

_offset=0
[ -f "$CACHE/offset" ] && _offset=$(cat "$CACHE/offset")
printf 'Đang lắng nghe update (Ctrl-C để dừng)...\n' >&2

while :; do
	_batch=$(api getUpdates --data-urlencode "offset=$_offset" \
		--data-urlencode "timeout=$POLL" --data-urlencode "limit=100")

	if ! api_ok "$_batch"; then
		printf 'getUpdates lỗi: %s\n' "$(api_desc "$_batch")" >&2
		sleep 2
		continue
	fi

	_last=$(printf '%s' "$_batch" | jq -r '[.result[].update_id] | max // empty' 2>/dev/null)
	[ -n "$_last" ] && _offset=$((_last + 1))

	for _cid in $(printf '%s' "$_batch" | extract_ids | sort -u); do
		_f=$CACHE/chats/$_cid.json
		if [ ! -f "$_f" ]; then
			resolve "$_cid" 0
			[ -f "$CACHE/chats/$_cid.json" ] && _f=$CACHE/chats/$_cid.json
			jq -r '"+ \(.id)  \(.type // "?")  \(if (.title // "") == "" then "-" else .title end)  [\(.bot_status // "-")]"' \
				"$_f" 2>/dev/null
		fi
	done

	printf '%s\n' "$_offset" >"$CACHE/offset"
done
