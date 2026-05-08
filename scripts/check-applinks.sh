#!/usr/bin/env bash
#
# Universal Links / App Links 검증 스크립트.
#
# 사용:
#   bash scripts/check-applinks.sh [base-url]
#
# 기본 base-url: https://terraworld.app
#
# 검사 항목:
#   1) HTTP 200 응답 확인
#   2) Content-Type: application/json
#   3) JSON 유효성 (jq parse)
#   4) placeholder 잔존 검사 (TEAMID / SHA256_FINGERPRINT_HERE)
#   5) iOS appIDs 가 mobile/capacitor.config.ts 의 appId 와 일치하는 형태인지 (.app.terraworld.mobile suffix)
#   6) Android package_name = app.terraworld.mobile
#
# 종료 코드: 0 = 모두 통과, 1+ = 하나 이상 실패 (실패 개수 만큼).
#
# 의존: curl, jq

set -uo pipefail

BASE_URL="${1:-https://terraworld.app}"
EXPECTED_BUNDLE="app.terraworld.mobile"

fail=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; fail=$((fail + 1)); }
err()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

check_endpoint() {
    local label=$1 path=$2
    printf '\n[%s] %s%s\n' "$label" "$BASE_URL" "$path"

    local body status
    body=$(curl -sS -o /tmp/applinks-body -w '%{http_code}\n%{content_type}' "$BASE_URL$path" 2>/dev/null) || {
        err "fetch 실패 (네트워크 / DNS / TLS)"
        return
    }
    status=$(echo "$body" | head -1)
    local ctype
    ctype=$(echo "$body" | tail -1)

    [ "$status" = "200" ] && pass "HTTP 200" || err "HTTP $status (200 기대)"

    case "$ctype" in
        application/json*) pass "Content-Type: $ctype" ;;
        *) err "Content-Type: $ctype (application/json 기대)" ;;
    esac

    if ! jq empty /tmp/applinks-body 2>/dev/null; then
        err "응답이 유효한 JSON 이 아님"
        return
    fi
    pass "JSON 유효"

    # placeholder 잔존
    if grep -q "TEAMID\|SHA256_FINGERPRINT_HERE" /tmp/applinks-body 2>/dev/null; then
        err "placeholder 잔존 (배포 전 SECRETS.md §5b 참조해 치환 필요)"
        head -c 200 /tmp/applinks-body
        echo
    else
        pass "placeholder 미검출"
    fi
}

check_endpoint "AASA"        "/.well-known/apple-app-site-association"

# AASA 추가 검사: appIDs 가 *.${EXPECTED_BUNDLE} 형식인지
if [ -s /tmp/applinks-body ]; then
    appids=$(jq -r '.applinks.details[]?.appIDs[]?' /tmp/applinks-body 2>/dev/null || echo "")
    if [ -z "$appids" ]; then
        err "applinks.details[].appIDs[] 부재"
    else
        while IFS= read -r appid; do
            case "$appid" in
                *".$EXPECTED_BUNDLE") pass "appID = $appid" ;;
                *) err "appID = $appid (suffix .$EXPECTED_BUNDLE 기대)" ;;
            esac
        done <<<"$appids"
    fi
fi

check_endpoint "assetlinks"  "/.well-known/assetlinks.json"

# assetlinks 추가 검사: package_name 일치
if [ -s /tmp/applinks-body ]; then
    pkg=$(jq -r '.[0].target.package_name' /tmp/applinks-body 2>/dev/null || echo "")
    if [ "$pkg" = "$EXPECTED_BUNDLE" ]; then
        pass "package_name = $pkg"
    else
        err "package_name = $pkg ($EXPECTED_BUNDLE 기대)"
    fi
    fp=$(jq -r '.[0].target.sha256_cert_fingerprints[0]' /tmp/applinks-body 2>/dev/null || echo "")
    case "$fp" in
        SHA256_FINGERPRINT_HERE|"")
            err "sha256_cert_fingerprints 미설정 또는 placeholder"
            ;;
        *:*)
            # 콜론 구분 16진수 32바이트 = 95자 (32*2 + 31 콜론)
            if [ "${#fp}" -eq 95 ]; then
                pass "sha256 fingerprint 길이 정상 (95자)"
            else
                warn "sha256 fingerprint 길이 ${#fp} (95 기대 — Play App Signing keystore 와 다른 변종일 수 있음)"
            fi
            ;;
        *)
            warn "sha256 fingerprint 형식 의심 (콜론 구분 16진수 권장)"
            ;;
    esac
fi

rm -f /tmp/applinks-body

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
else
    printf '\033[31m%d check(s) failed.\033[0m\n' "$fail"
    exit "$fail"
fi
