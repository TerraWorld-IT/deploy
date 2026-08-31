#!/bin/sh
# TerraWorld self-hosted Mac 배포 호스트 점검/부트스트랩.
# 기본은 읽기 전용 점검이다. 영구 변경은 --apply 를 명시했을 때만 수행한다.
set -u
umask 077

MODE=check
CONFIG_FILE=

# 시크릿 또는 호스트 경로가 든 임시 산출물은 정상 종료와 시그널 종료 모두에서 정리한다.
CREATE_TMP=
COMPOSE_PAYLOAD_TMP=
RUNNER_ENV_TMP=
RUNNER_ENV_LOCK=

cleanup() {
  CLEANUP_STATUS=$?
  trap - 0 HUP INT TERM

  if [ -n "$CREATE_TMP" ] && [ -e "$CREATE_TMP" ]; then
    if ! rm -f "$CREATE_TMP"; then
      printf '[경고] deploy .env 임시 파일 정리 실패: %s\n' "$CREATE_TMP" >&2
    fi
  fi
  if [ -n "$COMPOSE_PAYLOAD_TMP" ] && [ -e "$COMPOSE_PAYLOAD_TMP" ]; then
    if ! rm -f "$COMPOSE_PAYLOAD_TMP"; then
      printf '[경고] compose payload 임시 파일 정리 실패: %s\n' "$COMPOSE_PAYLOAD_TMP" >&2
    fi
  fi
  if [ -n "$RUNNER_ENV_TMP" ] && [ -e "$RUNNER_ENV_TMP" ]; then
    if ! rm -f "$RUNNER_ENV_TMP"; then
      printf '[경고] runner .env 임시 파일 정리 실패: %s\n' "$RUNNER_ENV_TMP" >&2
    fi
  fi
  if [ -n "$RUNNER_ENV_LOCK" ] && [ -d "$RUNNER_ENV_LOCK" ]; then
    if ! rmdir "$RUNNER_ENV_LOCK"; then
      printf '[경고] runner .env lock 정리 실패: %s\n' "$RUNNER_ENV_LOCK" >&2
    fi
  fi

  exit "$CLEANUP_STATUS"
}

on_signal() {
  exit "$1"
}

trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

usage() {
  printf '%s\n' \
    '사용: bash scripts/bootstrap-mac-host.sh [--check|--apply] [--config PATH]' \
    '' \
    '  --check        영구 변경 없이 호스트 계약을 점검한다(기본값).' \
    '  --apply        preflight blocker가 없을 때만 없는 파일과 runner 서비스를 준비한다.' \
    '  --config PATH  값 파일 경로를 지정한다(기본: deploy/mac-host.env).' \
    '  -h, --help     도움말을 표시한다.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --apply)
      MODE=apply
      ;;
    --config)
      shift
      if [ "$#" -eq 0 ]; then
        printf '%s\n' '[오류] --config 뒤에 경로가 필요합니다.' >&2
        exit 2
      fi
      CONFIG_FILE=$1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[오류] 알 수 없는 인자: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
SOURCE_DEPLOY_DIR=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)
if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE=$SOURCE_DEPLOY_DIR/mac-host.env
fi

# 존재하는 상대 경로는 저장소 내부 판정과 메시지가 일관되도록 물리 절대 경로로 정규화한다.
if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
  CONFIG_PARENT=$(CDPATH= cd "$(dirname "$CONFIG_FILE")" && pwd -P) || {
    printf '[오류] 값 파일의 상위 디렉터리를 확인할 수 없습니다: %s\n' "$CONFIG_FILE" >&2
    exit 2
  }
  CONFIG_FILE=$CONFIG_PARENT/$(basename "$CONFIG_FILE")
fi

OK_COUNT=0
WARN_COUNT=0
BLOCKER_COUNT=0
CHANGE_COUNT=0

CONFIG_FILE_READY=0
DEPLOY_DIR_CONFIG_READY=0
RUNNER_DIR_CONFIG_READY=0
RUNNER_SCOPE_CONFIG_READY=0
RUNNER_NAME_CONFIG_READY=0
COMPOSE_CONFIG_READY=0
DEPLOY_ENV_NEEDS_CREATE=0
RUNNER_ENV_ACTION=none
RUNNER_ENV_CHANGED=0
RUNNER_ENV_READY=0
SERVICE_ACTION=none
SERVICE_IS_RUNNING=0

DOCKER_READY=0
DOCKER_CLI_READY=0
COMPOSE_PLUGIN_READY=0
IS_MAC=0

EXPECTED_REGISTRY_URL=ghcr.io/terraworld-it

ok() {
  OK_COUNT=$((OK_COUNT + 1))
  printf '[준비] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[확인 필요] %s\n' "$*"
}

blocker() {
  BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
  printf '[누락] %s\n' "$*" >&2
}

changed() {
  CHANGE_COUNT=$((CHANGE_COUNT + 1))
  printf '[변경] %s\n' "$*"
}

read_config_value() {
  if [ "$CONFIG_FILE_READY" -ne 1 ]; then
    return 0
  fi
  sed -n "s/^$1=//p" "$CONFIG_FILE"
}

config_key_count() {
  if [ "$CONFIG_FILE_READY" -ne 1 ]; then
    printf '0\n'
    return 0
  fi
  grep -c "^$1=" "$CONFIG_FILE" 2>/dev/null || true
}

is_unfilled() {
  case "$1" in
    ''|*__FILL_*) return 0 ;;
    *) return 1 ;;
  esac
}

check_config_file_security() {
  CONFIG_SECURITY_VALID=1

  if [ -L "$CONFIG_FILE" ]; then
    blocker '값 파일은 symlink일 수 없습니다.'
    return
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    blocker "값 파일 없음: cp '$SOURCE_DEPLOY_DIR/mac-host.env.example' '$SOURCE_DEPLOY_DIR/mac-host.env' 후 값을 채우세요."
    return
  fi

  # 공개 템플릿은 check 입력으로만 허용한다. 실제 값 생성에는 사용할 수 없다.
  if [ "$CONFIG_FILE" = "$SOURCE_DEPLOY_DIR/mac-host.env.example" ]; then
    CONFIG_FILE_READY=1
    ok '공개 example 값 파일 확인(check 전용, 시크릿 입력 금지).'
    if [ "$MODE" = apply ]; then
      blocker 'mac-host.env.example은 --apply 값 파일로 사용할 수 없습니다. ignore되는 mac-host.env를 만드세요.'
    fi
    return
  fi

  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      CONFIG_MODE=$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)
      ;;
    *)
      CONFIG_MODE=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
      ;;
  esac
  if [ "$CONFIG_MODE" = 600 ]; then
    ok '값 파일 권한 600 확인.'
  else
    blocker "값 파일 권한이 600이 아닙니다(현재 ${CONFIG_MODE:-미확인}): chmod 600을 적용하세요."
    CONFIG_SECURITY_VALID=0
  fi

  case "$CONFIG_FILE" in
    "$SOURCE_DEPLOY_DIR"/*)
      CONFIG_RELATIVE=${CONFIG_FILE#"$SOURCE_DEPLOY_DIR"/}
      CONFIG_IGNORE_MATCH=
      if command -v git >/dev/null 2>&1; then
        CONFIG_IGNORE_MATCH=$(git -C "$SOURCE_DEPLOY_DIR" check-ignore -v -- "$CONFIG_RELATIVE" 2>/dev/null || true)
      fi
      CONFIG_IGNORE_SOURCE=${CONFIG_IGNORE_MATCH%%:*}
      case "$CONFIG_IGNORE_SOURCE" in
        .gitignore|*/.gitignore)
          ok '저장소 안 값 파일이 repository .gitignore 대상임을 확인.'
          ;;
        *)
          blocker '저장소 안 --config 경로는 gitignore 대상이어야 합니다. 공개 경로의 값 파일은 사용하지 않습니다.'
          CONFIG_SECURITY_VALID=0
          ;;
      esac
      ;;
    *)
      ok '값 파일이 public deploy 저장소 밖에 있음.'
      ;;
  esac

  if [ "$CONFIG_SECURITY_VALID" -eq 1 ]; then
    CONFIG_FILE_READY=1
  fi
}

check_single_config_key() {
  CHECK_KEY=$1
  CHECK_VALUE=$2
  CHECK_COUNT=$(config_key_count "$CHECK_KEY")
  if [ "$CHECK_COUNT" -ne 1 ]; then
    blocker "값 파일의 $CHECK_KEY 항목은 정확히 1개여야 합니다(현재 $CHECK_COUNT개)."
    return 1
  fi
  if is_unfilled "$CHECK_VALUE"; then
    blocker "값 파일의 $CHECK_KEY 값을 채워야 합니다."
    return 1
  fi
  return 0
}

check_safe_absolute_path() {
  PATH_LABEL=$1
  PATH_VALUE=$2

  case "$PATH_VALUE" in
    /*) ;;
    *)
      blocker "$PATH_LABEL 은 ~ 또는 상대 경로가 아닌 절대 경로여야 합니다."
      return 1
      ;;
  esac
  case "$PATH_VALUE" in
    *[!A-Za-z0-9._/:+@=-]*)
      blocker "$PATH_LABEL 에 허용되지 않은 문자가 있습니다. 공백, 따옴표, \$, 백틱은 사용할 수 없습니다."
      return 1
      ;;
  esac
  return 0
}

check_runner_scope_url() {
  case "$1" in
    https://github.com/*)
      RUNNER_SCOPE_SUFFIX=${1#https://github.com/}
      case "$RUNNER_SCOPE_SUFFIX" in
        ''|*[!A-Za-z0-9._/-]*)
          blocker 'TERRAWORLD_RUNNER_SCOPE_URL 경로에는 영문, 숫자, 점, 밑줄, 슬래시, 하이픈만 사용할 수 있습니다.'
          return 1
          ;;
        *)
          ok 'runner 등록 범위 URL 형식과 허용 문자 확인.'
          return 0
          ;;
      esac
      ;;
    *)
      blocker 'TERRAWORLD_RUNNER_SCOPE_URL 은 https://github.com/... 형식이어야 합니다.'
      return 1
      ;;
  esac
}

check_runner_name() {
  case "$1" in
    *[!A-Za-z0-9._-]*)
      blocker 'TERRAWORLD_RUNNER_NAME에는 영문, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다.'
      return 1
      ;;
    *)
      ok 'runner 이름 허용 문자 확인.'
      return 0
      ;;
  esac
}

extract_compose_payload() {
  BEGIN_COUNT=$(grep -c '^# === TERRAWORLD_COMPOSE_ENV_BEGIN ===$' "$CONFIG_FILE" 2>/dev/null || true)
  END_COUNT=$(grep -c '^# === TERRAWORLD_COMPOSE_ENV_END ===$' "$CONFIG_FILE" 2>/dev/null || true)
  if [ "$BEGIN_COUNT" -ne 1 ] || [ "$END_COUNT" -ne 1 ]; then
    blocker '값 파일의 compose env 시작/끝 경계가 각각 정확히 1개여야 합니다.'
    return 1
  fi

  COMPOSE_PAYLOAD_TMP=$(mktemp "${TMPDIR:-/tmp}/terraworld-compose-env.XXXXXX") || {
    blocker 'compose env 구간을 검증할 임시 파일을 만들 수 없습니다.'
    return 1
  }
  if ! awk '
      $0 == "# === TERRAWORLD_COMPOSE_ENV_BEGIN ===" {
        if (inside || began) exit 1
        inside = 1
        began = 1
        next
      }
      $0 == "# === TERRAWORLD_COMPOSE_ENV_END ===" {
        if (!inside) exit 1
        inside = 0
        ended = 1
        next
      }
      inside { print }
      END { if (!began || !ended || inside) exit 1 }
    ' "$CONFIG_FILE" > "$COMPOSE_PAYLOAD_TMP"; then
    blocker 'compose env 경계의 순서가 잘못되어 payload를 추출할 수 없습니다.'
    return 1
  fi
  if ! chmod 600 "$COMPOSE_PAYLOAD_TMP"; then
    blocker 'compose payload 임시 파일 권한을 600으로 제한하지 못했습니다.'
    return 1
  fi
  return 0
}

validate_env_values() {
  ENV_SOURCE=$1
  ENV_LABEL=$2
  ENV_STRICT=$3
  ENV_VALID=1

  if [ "$ENV_STRICT" = strict ]; then
    ENV_LINE_NO=0
    while IFS= read -r ENV_LINE || [ -n "$ENV_LINE" ]; do
      ENV_LINE_NO=$((ENV_LINE_NO + 1))
      case "$ENV_LINE" in
        ''|\#*) continue ;;
      esac
      case "$ENV_LINE" in
        *=*) ;;
        *)
          blocker "$ENV_LABEL: ${ENV_LINE_NO}번째 줄은 KEY=value 또는 주석 형식이어야 합니다."
          ENV_VALID=0
          continue
          ;;
      esac

      ENV_KEY=${ENV_LINE%%=*}
      ENV_VALUE=${ENV_LINE#*=}
      case "$ENV_KEY" in
        ''|[0-9]*|*[!A-Za-z0-9_]*)
          blocker "$ENV_LABEL: ${ENV_LINE_NO}번째 줄의 키 형식이 올바르지 않습니다."
          ENV_VALID=0
          continue
          ;;
      esac
      case "$ENV_VALUE" in
        *[!A-Za-z0-9._/:?@%+,=\&~+-]*)
          blocker "$ENV_LABEL: $ENV_KEY 값은 Compose 안전 문자 계약을 벗어났습니다. 공백, 따옴표, \$, 백슬래시, #, 백틱은 허용하지 않습니다."
          ENV_VALID=0
          ;;
      esac
    done < "$ENV_SOURCE"

    ENV_DUPLICATES=$(awk -F= '
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        if (++seen[$1] == 2) print $1
      }
    ' "$ENV_SOURCE")
    if [ -n "$ENV_DUPLICATES" ]; then
      blocker "$ENV_LABEL: 중복 키가 있습니다: $ENV_DUPLICATES"
      ENV_VALID=0
    fi
  fi

  for ENV_KEY in \
    DEPLOY_DOMAIN DB_NAME DB_USER DB_PASSWORD SPRING_DATASOURCE_URL DATABASE_URL \
    BETTER_AUTH_SECRET BETTER_AUTH_URL AUTH_JWKS_URL AUTH_JWT_ISSUER \
    AUTH_JWT_AUDIENCE INTERNAL_API_TOKEN INTERNAL_API_BASE_URL \
    CORS_ALLOWED_ORIGINS REDIS_HOST REDIS_PORT SPRING_PROFILES_ACTIVE \
    NUXT_PUBLIC_API_BASE_URL NUXT_PUBLIC_AUTH_BASE_URL REGISTRY_URL TAG; do
    ENV_COUNT=$(grep -c "^${ENV_KEY}=" "$ENV_SOURCE" 2>/dev/null || true)
    if [ "$ENV_COUNT" -ne 1 ]; then
      blocker "$ENV_LABEL: $ENV_KEY 항목은 정확히 1개여야 합니다(현재 $ENV_COUNT개)."
      ENV_VALID=0
      continue
    fi
    ENV_VALUE=$(sed -n "s/^${ENV_KEY}=//p" "$ENV_SOURCE")
    if is_unfilled "$ENV_VALUE"; then
      blocker "$ENV_LABEL: $ENV_KEY 값을 채워야 합니다."
      ENV_VALID=0
    elif [ "$ENV_KEY" = REGISTRY_URL ] && [ "$ENV_VALUE" != "$EXPECTED_REGISTRY_URL" ]; then
      blocker "$ENV_LABEL: REGISTRY_URL은 두 CI가 push하는 고정 prefix $EXPECTED_REGISTRY_URL 이어야 합니다."
      ENV_VALID=0
    fi
  done

  [ "$ENV_VALID" -eq 1 ]
}

create_deploy_env() {
  CREATE_TARGET=$1
  CREATE_SOURCE=$2

  if [ -e "$CREATE_TARGET" ] || [ -L "$CREATE_TARGET" ]; then
    return 1
  fi
  CREATE_TMP=$(mktemp "${CREATE_TARGET}.bootstrap.XXXXXX") || return 1
  if ! cp "$CREATE_SOURCE" "$CREATE_TMP"; then
    return 1
  fi
  if ! chmod 600 "$CREATE_TMP"; then
    return 1
  fi

  # 같은 디렉터리의 hard link 생성은 대상이 경합으로 생겼으면 실패하고, 완성된 inode만 공개한다.
  if ! ln "$CREATE_TMP" "$CREATE_TARGET"; then
    return 1
  fi
  if ! rm -f "$CREATE_TMP"; then
    warn "deploy .env는 생성됐지만 임시 파일 정리에 실패했습니다: $CREATE_TMP"
    return 2
  fi
  CREATE_TMP=
  return 0
}

runner_service_running() {
  SERVICE_MARKER=$1/.service
  if [ ! -f "$SERVICE_MARKER" ] || ! command -v launchctl >/dev/null 2>&1; then
    return 1
  fi
  SERVICE_PLIST=$(sed -n '1p' "$SERVICE_MARKER")
  if [ -z "$SERVICE_PLIST" ]; then
    return 1
  fi
  SERVICE_NAME=$(basename "$SERVICE_PLIST" .plist)
  launchctl list "$SERVICE_NAME" >/dev/null 2>&1
}

check_runner_env() {
  RUNNER_ENV_FILE=$1/.env

  if [ -L "$RUNNER_ENV_FILE" ]; then
    blocker "runner .env가 symlink입니다. 자동으로 읽거나 수정하지 않습니다: $RUNNER_ENV_FILE"
    return
  fi
  if [ -e "$RUNNER_ENV_FILE" ] && [ ! -f "$RUNNER_ENV_FILE" ]; then
    blocker "runner .env가 정규 파일이 아닙니다. 자동으로 읽거나 수정하지 않습니다: $RUNNER_ENV_FILE"
    return
  fi

  if [ ! -e "$RUNNER_ENV_FILE" ]; then
    if [ "$MODE" = apply ] && [ -w "$1" ]; then
      RUNNER_ENV_ACTION=create
      ok 'runner .env 신규 생성 가능(--apply 예정).'
    elif [ "$MODE" = apply ]; then
      blocker 'runner 디렉터리에 쓸 수 없어 .env를 생성할 수 없습니다.'
    else
      blocker "$RUNNER_ENV_FILE 없음: --apply 가 원자적으로 새 파일을 만들 수 있습니다."
    fi
    return
  fi

  if [ ! -r "$RUNNER_ENV_FILE" ]; then
    blocker "runner .env를 읽을 수 없습니다: $RUNNER_ENV_FILE"
    return
  fi

  RUNNER_ENV_COUNT=$(grep -c '^TERRAWORLD_DEPLOY_DIR=' "$RUNNER_ENV_FILE" 2>/dev/null || true)
  if [ "$RUNNER_ENV_COUNT" -eq 0 ]; then
    if [ "$MODE" = apply ] && [ -w "$1" ]; then
      RUNNER_ENV_ACTION=append
      ok 'runner .env에 경로 키 원자적 추가 가능(--apply 예정).'
    elif [ "$MODE" = apply ]; then
      blocker 'runner 디렉터리에 쓸 수 없어 .env를 원자적으로 교체할 수 없습니다.'
    else
      blocker "$RUNNER_ENV_FILE 에 TERRAWORLD_DEPLOY_DIR 없음: --apply 가 기존 키를 건드리지 않고 추가할 수 있습니다."
    fi
    return
  fi

  if [ "$RUNNER_ENV_COUNT" -ne 1 ]; then
    blocker "$RUNNER_ENV_FILE 에 TERRAWORLD_DEPLOY_DIR 가 ${RUNNER_ENV_COUNT}개입니다. 자동 수정하지 않습니다."
    return
  fi

  RUNNER_ENV_VALUE=$(sed -n 's/^TERRAWORLD_DEPLOY_DIR=//p' "$RUNNER_ENV_FILE")
  if [ "$RUNNER_ENV_VALUE" = "$TERRAWORLD_DEPLOY_DIR" ]; then
    RUNNER_ENV_READY=1
    ok "runner .env 경로 주입 일치: $RUNNER_ENV_FILE"
  else
    blocker "runner .env 의 TERRAWORLD_DEPLOY_DIR 값이 mac-host.env 와 다릅니다. 기존 값을 덮어쓰지 않았습니다."
  fi
}

discard_runner_env_tmp() {
  if [ -n "$RUNNER_ENV_TMP" ] && [ -e "$RUNNER_ENV_TMP" ]; then
    if rm -f "$RUNNER_ENV_TMP"; then
      RUNNER_ENV_TMP=
      return 0
    fi
    blocker "runner .env 임시 파일 정리 실패: $RUNNER_ENV_TMP"
    return 1
  fi
  RUNNER_ENV_TMP=
  return 0
}

release_runner_env_lock() {
  if [ -n "$RUNNER_ENV_LOCK" ] && [ -d "$RUNNER_ENV_LOCK" ]; then
    if rmdir "$RUNNER_ENV_LOCK"; then
      RUNNER_ENV_LOCK=
      return 0
    fi
    blocker "runner .env lock 정리 실패: $RUNNER_ENV_LOCK"
    return 1
  fi
  RUNNER_ENV_LOCK=
  return 0
}

verify_runner_env_tmp() {
  VERIFY_COUNT=$(grep -c '^TERRAWORLD_DEPLOY_DIR=' "$RUNNER_ENV_TMP" 2>/dev/null || true)
  VERIFY_VALUE=$(sed -n 's/^TERRAWORLD_DEPLOY_DIR=//p' "$RUNNER_ENV_TMP")
  [ "$VERIFY_COUNT" -eq 1 ] && [ "$VERIFY_VALUE" = "$TERRAWORLD_DEPLOY_DIR" ]
}

apply_runner_env() {
  RUNNER_ENV_FILE=$1/.env
  RUNNER_ENV_LINE=TERRAWORLD_DEPLOY_DIR=$TERRAWORLD_DEPLOY_DIR
  RUNNER_ENV_LOCK=$1/.env.bootstrap.lock
  RUNNER_ENV_COMMITTED=0
  RUNNER_ENV_APPLY_VALID=1

  if ! mkdir "$RUNNER_ENV_LOCK"; then
    blocker "runner .env lock 획득 실패: 다른 bootstrap 실행 또는 남은 lock을 확인하세요($RUNNER_ENV_LOCK)."
    RUNNER_ENV_LOCK=
    return
  fi

  RUNNER_ENV_TMP=$(mktemp "$1/.env.bootstrap.XXXXXX") || {
    blocker 'runner .env 임시 파일 생성 실패.'
    release_runner_env_lock || true
    return
  }

  case "$RUNNER_ENV_ACTION" in
    create)
      if [ -e "$RUNNER_ENV_FILE" ] || [ -L "$RUNNER_ENV_FILE" ]; then
        blocker 'runner .env가 preflight 뒤 생성되어 경합을 감지했습니다. 기존 파일은 건드리지 않습니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] &&
        ! printf '%s\n' "$RUNNER_ENV_LINE" > "$RUNNER_ENV_TMP"; then
        blocker 'runner .env 임시 파일 기록 실패.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] && ! chmod 600 "$RUNNER_ENV_TMP"; then
        blocker 'runner .env 임시 파일 권한을 600으로 제한하지 못했습니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] && ! verify_runner_env_tmp; then
        blocker 'runner .env 임시 파일 검증 실패: 정확히 한 경로 키만 있어야 합니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ]; then
        if ln "$RUNNER_ENV_TMP" "$RUNNER_ENV_FILE"; then
          RUNNER_ENV_COMMITTED=1
        else
          blocker 'runner .env 원자적 생성 실패: 대상 파일 경합을 확인하세요.'
          RUNNER_ENV_APPLY_VALID=0
        fi
      fi
      ;;
    append)
      if [ -L "$RUNNER_ENV_FILE" ] || [ ! -f "$RUNNER_ENV_FILE" ]; then
        blocker 'runner .env 파일 타입이 preflight 뒤 바뀌었습니다. 기존 경로는 건드리지 않습니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ]; then
        RUNNER_ENV_COUNT=$(grep -c '^TERRAWORLD_DEPLOY_DIR=' "$RUNNER_ENV_FILE" 2>/dev/null || true)
        if [ "$RUNNER_ENV_COUNT" -ne 0 ]; then
          blocker 'runner .env 키가 preflight 뒤 바뀌어 경합을 감지했습니다. 기존 파일은 건드리지 않습니다.'
          RUNNER_ENV_APPLY_VALID=0
        fi
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ]; then
        RUNNER_ENV_ORIGINAL_CKSUM=$(cksum "$RUNNER_ENV_FILE" 2>/dev/null || true)
        if [ -z "$RUNNER_ENV_ORIGINAL_CKSUM" ] || ! cp "$RUNNER_ENV_FILE" "$RUNNER_ENV_TMP"; then
          blocker 'runner .env를 임시 파일로 안전하게 복사하지 못했습니다.'
          RUNNER_ENV_APPLY_VALID=0
        fi
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] &&
        ! printf '\n%s\n' "$RUNNER_ENV_LINE" >> "$RUNNER_ENV_TMP"; then
        blocker 'runner .env 임시 파일에 경로 키를 추가하지 못했습니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] && ! chmod 600 "$RUNNER_ENV_TMP"; then
        blocker 'runner .env 임시 파일 권한을 600으로 제한하지 못했습니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ] && ! verify_runner_env_tmp; then
        blocker 'runner .env 임시 파일 검증 실패: 경로 키가 정확히 한 개가 아닙니다.'
        RUNNER_ENV_APPLY_VALID=0
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ]; then
        RUNNER_ENV_CURRENT_CKSUM=$(cksum "$RUNNER_ENV_FILE" 2>/dev/null || true)
        if [ "$RUNNER_ENV_CURRENT_CKSUM" != "$RUNNER_ENV_ORIGINAL_CKSUM" ] ||
          [ -L "$RUNNER_ENV_FILE" ] || [ ! -f "$RUNNER_ENV_FILE" ]; then
          blocker 'runner .env가 복사 뒤 바뀌어 경합을 감지했습니다. 원본은 덮어쓰지 않습니다.'
          RUNNER_ENV_APPLY_VALID=0
        fi
      fi
      if [ "$RUNNER_ENV_APPLY_VALID" -eq 1 ]; then
        if mv "$RUNNER_ENV_TMP" "$RUNNER_ENV_FILE"; then
          RUNNER_ENV_TMP=
          RUNNER_ENV_COMMITTED=1
        else
          blocker 'runner .env 원자적 교체 실패. 원본은 그대로 남아 있습니다.'
          RUNNER_ENV_APPLY_VALID=0
        fi
      fi
      ;;
    *)
      blocker 'runner .env apply 동작이 결정되지 않았습니다.'
      RUNNER_ENV_APPLY_VALID=0
      ;;
  esac

  if [ "$RUNNER_ENV_COMMITTED" -eq 1 ]; then
    if [ "$RUNNER_ENV_ACTION" = create ]; then
      changed "$RUNNER_ENV_FILE 생성(TERRAWORLD_DEPLOY_DIR만 기록, 권한 600)."
    else
      changed "$RUNNER_ENV_FILE 에 TERRAWORLD_DEPLOY_DIR 원자적 추가(기존 내용 보존, 교체 파일 권한 600)."
    fi
    RUNNER_ENV_CHANGED=1
    RUNNER_ENV_READY=1
  fi

  discard_runner_env_tmp || true
  release_runner_env_lock || true
}

printf 'TerraWorld Mac 배포 호스트 bootstrap (%s 모드)\n' "$MODE"
printf '값 파일: %s\n\n' "$CONFIG_FILE"

if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
  IS_MAC=1
  ok '운영체제: macOS'
else
  blocker '운영체제가 macOS가 아닙니다. 이 스크립트는 배포 Mac 전용입니다.'
fi

check_config_file_security

TERRAWORLD_DEPLOY_DIR=
TERRAWORLD_RUNNER_DIR=
TERRAWORLD_RUNNER_SCOPE_URL=
TERRAWORLD_RUNNER_NAME=

if [ "$CONFIG_FILE_READY" -eq 1 ]; then
  TERRAWORLD_DEPLOY_DIR=$(read_config_value TERRAWORLD_DEPLOY_DIR)
  TERRAWORLD_RUNNER_DIR=$(read_config_value TERRAWORLD_RUNNER_DIR)
  TERRAWORLD_RUNNER_SCOPE_URL=$(read_config_value TERRAWORLD_RUNNER_SCOPE_URL)
  TERRAWORLD_RUNNER_NAME=$(read_config_value TERRAWORLD_RUNNER_NAME)

  if check_single_config_key TERRAWORLD_DEPLOY_DIR "$TERRAWORLD_DEPLOY_DIR" &&
    check_safe_absolute_path TERRAWORLD_DEPLOY_DIR "$TERRAWORLD_DEPLOY_DIR"; then
    DEPLOY_DIR_CONFIG_READY=1
  fi
  if check_single_config_key TERRAWORLD_RUNNER_DIR "$TERRAWORLD_RUNNER_DIR" &&
    check_safe_absolute_path TERRAWORLD_RUNNER_DIR "$TERRAWORLD_RUNNER_DIR"; then
    RUNNER_DIR_CONFIG_READY=1
  fi
  if check_single_config_key TERRAWORLD_RUNNER_SCOPE_URL "$TERRAWORLD_RUNNER_SCOPE_URL" &&
    check_runner_scope_url "$TERRAWORLD_RUNNER_SCOPE_URL"; then
    RUNNER_SCOPE_CONFIG_READY=1
  fi
  if check_single_config_key TERRAWORLD_RUNNER_NAME "$TERRAWORLD_RUNNER_NAME" &&
    check_runner_name "$TERRAWORLD_RUNNER_NAME"; then
    RUNNER_NAME_CONFIG_READY=1
  fi
fi

if [ "$IS_MAC" -eq 1 ]; then
  HOST_ARCH=$(uname -m 2>/dev/null || true)
  if [ "$HOST_ARCH" = arm64 ]; then
    ok '호스트 아키텍처: Apple Silicon(arm64).'
    if /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      ok 'Rosetta 2 x86_64 실행 가능(amd64 이미지 에뮬레이션 전제).'
    else
      blocker "Rosetta 2로 x86_64 실행이 불가능합니다: 'softwareupdate --install-rosetta' 후 재점검하세요."
    fi
  else
    ok "호스트 아키텍처: ${HOST_ARCH:-미확인}(Rosetta 점검 불필요)."
  fi
fi

WORKFLOW_PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
if [ "$IS_MAC" -eq 1 ]; then
  if PATH="$WORKFLOW_PATH" command -v docker >/dev/null 2>&1; then
    DOCKER_CLI_READY=1
    ok '워크플로 PATH에서 docker CLI 발견(/opt/homebrew/bin 포함).'
    if PATH="$WORKFLOW_PATH" docker info >/dev/null 2>&1; then
      DOCKER_READY=1
      ok 'Docker daemon 응답.'
    else
      blocker 'docker CLI는 있지만 daemon이 응답하지 않습니다. Docker Desktop 실행 상태를 확인하세요.'
    fi
  else
    blocker '워크플로 PATH에서 docker CLI를 찾지 못했습니다. Docker Desktop 설치/CLI 경로를 확인하세요.'
  fi

  if [ "$DOCKER_CLI_READY" -eq 1 ]; then
    if PATH="$WORKFLOW_PATH" docker compose version >/dev/null 2>&1; then
      COMPOSE_PLUGIN_READY=1
      ok 'Docker Compose v2 플러그인 응답.'
    else
      blocker "'docker compose' 플러그인을 찾지 못했습니다. Docker Desktop/Compose v2를 확인하세요."
    fi
  fi
else
  warn '비-macOS 검증에서는 docker CLI/daemon/compose 실행을 하지 않음(NOT_RUN).'
fi

if [ -n "${HOME:-}" ] && [ -d "$HOME/.docker/cli-plugins" ]; then
  ok 'runner 임시 DOCKER_CONFIG에 연결할 $HOME/.docker/cli-plugins 디렉터리 존재.'
elif [ -z "${HOME:-}" ]; then
  blocker 'HOME 환경변수가 없어 runner Docker 플러그인 경로를 결정할 수 없습니다.'
else
  warn '$HOME/.docker/cli-plugins 없음: compose가 전역 경로에서 동작해도 워크플로의 symlink 단계는 건너뜁니다.'
fi

if [ -d "${TMPDIR:-/tmp}" ] && [ -w "${TMPDIR:-/tmp}" ]; then
  ok '임시 DOCKER_CONFIG와 검증 payload를 만들 임시 디렉터리 쓰기 가능.'
else
  blocker 'TMPDIR에 쓸 수 없어 워크플로 임시 DOCKER_CONFIG와 bootstrap 검증 파일 생성이 막힙니다.'
fi

CHECK_DEPLOY_DIR=$TERRAWORLD_DEPLOY_DIR
if [ "$DEPLOY_DIR_CONFIG_READY" -ne 1 ]; then
  CHECK_DEPLOY_DIR=$SOURCE_DEPLOY_DIR
fi

DEPLOY_DIR_EXISTS=0
BASE_COMPOSE_READY=0
TUNNEL_COMPOSE_READY=0
if [ -d "$CHECK_DEPLOY_DIR" ]; then
  DEPLOY_DIR_EXISTS=1
  ok "배포 디렉터리 존재: $CHECK_DEPLOY_DIR"
else
  blocker "배포 디렉터리 없음: $CHECK_DEPLOY_DIR (deploy 저장소를 이 절대 경로에 checkout 해야 합니다)."
fi

BASE_COMPOSE=$CHECK_DEPLOY_DIR/docker-compose.yml
TUNNEL_COMPOSE=$CHECK_DEPLOY_DIR/docker-compose.tunnel.yml
DEPLOY_ENV=$CHECK_DEPLOY_DIR/.env

if [ -f "$BASE_COMPOSE" ]; then
  BASE_COMPOSE_READY=1
  ok 'docker-compose.yml 존재.'
  if grep -q 'container_name: tw-backend' "$BASE_COMPOSE" &&
    grep -q 'container_name: tw-frontend' "$BASE_COMPOSE"; then
    ok 'compose 컨테이너 이름 계약: tw-backend, tw-frontend.'
  else
    blocker 'docker-compose.yml 에 tw-backend/tw-frontend container_name 계약이 없습니다.'
  fi
else
  blocker "docker-compose.yml 없음: $BASE_COMPOSE"
fi

if [ -f "$TUNNEL_COMPOSE" ]; then
  TUNNEL_COMPOSE_READY=1
  ok '호스트 로컬 docker-compose.tunnel.yml 존재(내용은 출력하지 않음).'
else
  blocker 'docker-compose.tunnel.yml 없음. 키/내용이 미확인이므로 bootstrap은 생성하거나 복사하지 않습니다.'
fi

COMPOSE_ENV_FOR_VALIDATION=
if [ -f "$DEPLOY_ENV" ]; then
  ok 'deploy/.env 존재(내용은 출력하지 않음).'
  COMPOSE_ENV_FOR_VALIDATION=$DEPLOY_ENV
  validate_env_values "$DEPLOY_ENV" '기존 deploy/.env' existing || true
elif [ "$CONFIG_FILE_READY" -eq 1 ] && [ "$DEPLOY_DIR_CONFIG_READY" -eq 1 ]; then
  if extract_compose_payload &&
    validate_env_values "$COMPOSE_PAYLOAD_TMP" '값 파일 compose payload' strict; then
    COMPOSE_CONFIG_READY=1
    COMPOSE_ENV_FOR_VALIDATION=$COMPOSE_PAYLOAD_TMP
    ok 'marker 안에서 추출한 deploy/.env 생성 payload 검증 완료.'
    if [ "$MODE" = apply ] && [ "$DEPLOY_DIR_EXISTS" -eq 1 ] &&
      [ "$BASE_COMPOSE_READY" -eq 1 ]; then
      DEPLOY_ENV_NEEDS_CREATE=1
      ok 'deploy/.env 신규 생성 가능(--apply 예정).'
    else
      blocker 'deploy/.env 없음: 검증된 값을 사용해 --apply 로 새로 만들 수 있습니다.'
    fi
  fi
else
  blocker 'deploy/.env 없음: 안전한 호스트 경로와 값 파일을 먼저 준비하세요.'
fi

if [ "$COMPOSE_PLUGIN_READY" -eq 1 ] && [ "$BASE_COMPOSE_READY" -eq 1 ] &&
  [ "$TUNNEL_COMPOSE_READY" -eq 1 ] && [ -n "$COMPOSE_ENV_FOR_VALIDATION" ]; then
  if (
    cd "$CHECK_DEPLOY_DIR" &&
      PATH="$WORKFLOW_PATH" docker compose --env-file "$COMPOSE_ENV_FOR_VALIDATION" \
        -f docker-compose.yml -f docker-compose.tunnel.yml config --quiet
  ); then
    ok '실배포 compose 조합(base + tunnel) 해석 성공.'
  else
    blocker '실배포 compose 조합 해석 실패: .env와 tunnel override의 정확한 키/구조를 확인하세요.'
  fi
fi

if [ "$DOCKER_READY" -eq 1 ]; then
  for CONTAINER_NAME in tw-backend tw-frontend; do
    if PATH="$WORKFLOW_PATH" docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      ok "컨테이너 발견: $CONTAINER_NAME"
      CONTAINER_STATE=$(PATH="$WORKFLOW_PATH" docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)
      if [ "$CONTAINER_STATE" = running ]; then
        ok "컨테이너 실행 상태: $CONTAINER_NAME=running"
      else
        warn "컨테이너 실행 상태: $CONTAINER_NAME=${CONTAINER_STATE:-미확인}"
      fi
      if [ "$CONTAINER_NAME" = tw-backend ]; then
        BACKEND_HEALTH=$(PATH="$WORKFLOW_PATH" docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthcheck-없음{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
        case "$BACKEND_HEALTH" in
          healthy) ok 'backend health: healthy' ;;
          starting) warn 'backend health: starting (워크플로 최대 대기 예산 300초)' ;;
          *) warn "backend health: ${BACKEND_HEALTH:-미확인}" ;;
        esac
      fi
    else
      warn "컨테이너 없음: $CONTAINER_NAME (첫 배포 job이 생성하며 bootstrap은 기동하지 않음)."
    fi
  done
fi

if [ "$RUNNER_DIR_CONFIG_READY" -ne 1 ]; then
  blocker 'TERRAWORLD_RUNNER_DIR 미설정으로 runner 등록/서비스를 점검할 수 없습니다.'
elif [ ! -d "$TERRAWORLD_RUNNER_DIR" ]; then
  blocker "runner 디렉터리 없음: $TERRAWORLD_RUNNER_DIR"
else
  ok "runner 디렉터리 존재: $TERRAWORLD_RUNNER_DIR"
  if [ -f "$TERRAWORLD_RUNNER_DIR/config.sh" ]; then
    ok 'runner config.sh 존재.'
  else
    blocker 'runner config.sh 없음: GitHub Runners 화면의 macOS용 다운로드/압축 해제 명령을 먼저 실행하세요.'
  fi

  if [ -f "$TERRAWORLD_RUNNER_DIR/.runner" ]; then
    ok 'runner 로컬 등록 파일(.runner) 존재.'
    warn '라벨은 서버측 상태라 로컬 파일로 증명할 수 없습니다. GitHub UI에서 self-hosted와 terraworld를 모두 확인하세요.'

    if [ "$DEPLOY_DIR_CONFIG_READY" -eq 1 ] && [ -d "$TERRAWORLD_DEPLOY_DIR" ]; then
      check_runner_env "$TERRAWORLD_RUNNER_DIR"
    else
      blocker '유효한 TERRAWORLD_DEPLOY_DIR가 없어 runner .env를 점검하거나 수정하지 않습니다.'
    fi

    if [ -f "$TERRAWORLD_RUNNER_DIR/svc.sh" ]; then
      if runner_service_running "$TERRAWORLD_RUNNER_DIR"; then
        SERVICE_IS_RUNNING=1
        if [ "$RUNNER_ENV_ACTION" != none ]; then
          blocker '실행 중인 runner에 .env 변경이 필요합니다. bootstrap은 기존 서비스를 중지하지 않으므로 운영자가 먼저 안전하게 중지한 뒤 --apply를 재실행하세요.'
        elif [ "$RUNNER_ENV_READY" -eq 1 ]; then
          ok 'runner launchd 서비스가 이미 실행 중이므로 조작하지 않음.'
        fi
      elif [ "$MODE" = apply ] && {
        [ "$RUNNER_ENV_READY" -eq 1 ] || [ "$RUNNER_ENV_ACTION" != none ]
      }; then
        if [ -f "$TERRAWORLD_RUNNER_DIR/.service" ]; then
          SERVICE_ACTION=start
          ok '중지된 runner 서비스 시작 가능(--apply 마지막 단계 예정).'
        else
          SERVICE_ACTION=install_start
          ok 'runner 서비스 설치·시작 가능(--apply 마지막 단계 예정).'
        fi
      else
        blocker 'runner launchd 서비스가 준비되지 않았습니다. 등록과 runner .env를 준비한 뒤 --apply를 실행하세요.'
      fi
    else
      blocker 'runner svc.sh 없음: runner 패키지가 완전한지 확인하세요.'
    fi
  else
    blocker 'runner 미등록(.runner 없음). docs/mac-self-hosted-runner.md의 대화형 config.sh 절차를 실행하세요.'
    printf '%s\n' '  등록에 사용할 값(실행 명령이 아님):'
    if [ "$RUNNER_DIR_CONFIG_READY" -eq 1 ]; then
      printf '  - runner 디렉터리: %s\n' "$TERRAWORLD_RUNNER_DIR"
    else
      printf '%s\n' '  - runner 디렉터리: 유효성 검사 실패'
    fi
    if [ "$RUNNER_SCOPE_CONFIG_READY" -eq 1 ]; then
      printf '  - 등록 범위 URL: %s\n' "$TERRAWORLD_RUNNER_SCOPE_URL"
    else
      printf '%s\n' '  - 등록 범위 URL: 유효성 검사 실패'
    fi
    if [ "$RUNNER_NAME_CONFIG_READY" -eq 1 ]; then
      printf '  - runner 이름: %s\n' "$TERRAWORLD_RUNNER_NAME"
    else
      printf '%s\n' '  - runner 이름: 유효성 검사 실패'
    fi
    printf '%s\n' '  토큰은 파일/인자에 넣지 말고 문서의 placeholder 명령에서 대화형 프롬프트로만 입력하세요.'
  fi
fi

# apply는 전체 preflight가 끝난 뒤 시작한다. blocker가 있으면 파일과 서비스를 모두 그대로 둔다.
if [ "$MODE" = apply ]; then
  printf '\n%s\n' 'apply 단계'
  if [ "$BLOCKER_COUNT" -gt 0 ]; then
    warn 'preflight blocker가 있어 apply 전체를 건너뜀. 파일과 runner 서비스를 변경하지 않았습니다.'
  else
    if [ "$DEPLOY_ENV_NEEDS_CREATE" -eq 1 ]; then
      create_deploy_env "$DEPLOY_ENV" "$COMPOSE_PAYLOAD_TMP"
      CREATE_RESULT=$?
      case "$CREATE_RESULT" in
        0)
          changed "$DEPLOY_ENV 신규 생성(권한 600, 검증된 marker payload 사용)."
          ok 'deploy/.env 생성 완료.'
          ;;
        2)
          blocker 'deploy/.env 생성 뒤 시크릿 임시 파일 정리에 실패했습니다. 서비스 단계에 진입하지 않습니다.'
          ;;
        *)
          blocker 'deploy/.env 생성 실패: 기존 파일 경합 또는 쓰기 권한을 확인하세요. 기존 파일은 덮어쓰지 않았습니다.'
          ;;
      esac
    fi

    if [ "$RUNNER_ENV_ACTION" != none ]; then
      apply_runner_env "$TERRAWORLD_RUNNER_DIR"
    fi

    # 서비스 조작은 모든 파일 apply가 성공한 뒤의 마지막 단계다. 기존 실행 서비스는 중지하지 않는다.
    if [ "$BLOCKER_COUNT" -eq 0 ]; then
      case "$SERVICE_ACTION" in
        install_start)
          if [ -f "$TERRAWORLD_RUNNER_DIR/.service" ]; then
            blocker 'runner 서비스 상태가 preflight 뒤 바뀌어 자동 설치를 중단합니다.'
          elif (
            cd "$TERRAWORLD_RUNNER_DIR" &&
              ./svc.sh install
          ); then
            changed 'macOS launchd runner 서비스 설치.'
            SERVICE_ACTION=start
          else
            blocker 'runner 서비스 설치 실패: svc.sh 출력과 권한을 확인하세요.'
          fi
          ;;
      esac
    fi

    if [ "$BLOCKER_COUNT" -eq 0 ] && [ "$SERVICE_ACTION" = start ]; then
      if runner_service_running "$TERRAWORLD_RUNNER_DIR"; then
        ok 'runner 서비스가 외부에서 이미 시작되어 자동 start를 건너뜀.'
      elif (
        cd "$TERRAWORLD_RUNNER_DIR" &&
          ./svc.sh start
      ); then
        changed 'runner 서비스 시작.'
      else
        blocker 'runner 서비스 시작 실패. bootstrap은 기존 실행 서비스를 중지하지 않았습니다.'
      fi
    fi

    if [ "$BLOCKER_COUNT" -eq 0 ]; then
      if runner_service_running "$TERRAWORLD_RUNNER_DIR"; then
        ok 'runner launchd 서비스 실행 중.'
      else
        blocker 'runner 서비스 명령 뒤 launchd 실행 상태를 확인할 수 없습니다.'
      fi
    else
      warn '파일 apply 중 blocker가 생겨 runner 서비스 설치·시작에 진입하지 않았습니다.'
    fi
  fi
fi

printf '\n요약: 준비 %s, 확인 필요 %s, 누락 %s, 변경 %s\n' \
  "$OK_COUNT" "$WARN_COUNT" "$BLOCKER_COUNT" "$CHANGE_COUNT"

if [ "$MODE" = check ]; then
  printf '%s\n' 'check 모드에서는 영구 파일·서비스·컨테이너를 변경하지 않았습니다.'
else
  printf '%s\n' 'apply 모드에서도 기존 deploy/.env, 기존 runner 경로 키, 실행 중 runner 서비스, tunnel override는 덮어쓰거나 중지하지 않습니다.'
fi

if [ "$BLOCKER_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
