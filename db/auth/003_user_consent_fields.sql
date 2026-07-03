-- P1-3 (PIPA 제15조): 가입 분리 동의 이력 컬럼 추가.
--
-- 배경: terms §9 / privacy §2 가 '약관/필수 개인정보/선택/마케팅을 각각 구분 동의 +
--       동의 항목·버전·시각 기록'을 선언했으나 auth.user 에 저장 컬럼이 없어 동의 입증 불가.
--       login.vue 분리 동의 UI + server/lib/auth.ts additionalFields(input:true) 와 정합.
--
-- 추가 컬럼 (auth.user):
--   agreeTerms / agreePrivacy        — 필수 동의 (create.before 가 true 강제)
--   marketingConsent / analyticsConsent / adConsent / photoConsent / pushConsent — 선택 동의
--   consentVersion                   — 동의 시점의 정책 버전 (예: '2026-06-23')
--   consentedAt                      — 동의 시각 (ISO8601 문자열)
--
-- 운영 안전:
--   - IF NOT EXISTS 가드 — 재실행 안전
--   - boolean 컬럼 DEFAULT false (기존 row backfill 안전, NOT NULL 가능)
--   - frontend/server/db/migrations/ 의 수동 1회 적용 흐름 (Nitro auth schema —
--     Spring Flyway 가 관리하는 public schema 영향 X)
--
-- 적용:
--   psql "$DATABASE_URL" -f frontend/server/db/migrations/003_user_consent_fields.sql

SET search_path TO auth;

ALTER TABLE "user"
    ADD COLUMN IF NOT EXISTS "agreeTerms"        BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "agreePrivacy"      BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "marketingConsent"  BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "analyticsConsent"  BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "adConsent"         BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "photoConsent"      BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "pushConsent"       BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS "consentVersion"    TEXT,
    ADD COLUMN IF NOT EXISTS "consentedAt"       TEXT;

COMMENT ON COLUMN "user"."marketingConsent" IS 'P1-3 마케팅·광고성 정보 수신 동의 (정보통신망법 제50조). 철회 시 false 업데이트.';
COMMENT ON COLUMN "user"."consentVersion"   IS 'P1-3 동의 시점의 개인정보 처리방침/약관 버전.';
COMMENT ON COLUMN "user"."consentedAt"       IS 'P1-3 동의 시각 (ISO8601). 분쟁 시 동의 입증.';
