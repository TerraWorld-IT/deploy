-- LEGAL-001 fix follow-up (e2e cycle 2026-05-18 발견 → 2026-05-19 적용).
--
-- 본 cycle e2e 검증 결과: `frontend/server/lib/auth.ts` 의 better-auth
-- `databaseHooks.user.create.before` 가 birthDate 를 읽으려 하지만, default
-- additionalFields 미등록 + DB column 부재로 client signup payload 가 strip
-- 됨. 만 14세 이상도 가입 차단.
--
-- 본 migration:
--   1. auth.user 테이블에 birthDate TEXT 컬럼 추가
--   2. 기존 row 부재 (e2e cycle 시점 production user 0건 — Phase 4 pre-launch)
--      라 backfill 불필요. NOT NULL 추가 가능
--
-- 운영 안전:
--   - IF NOT EXISTS 가드 — 재실행 안전
--   - 본 SQL 은 frontend/server/db/migrations/ 의 수동 1회 적용 흐름
--     (frontend Nitro 측 — Spring Flyway 가 관리하는 public schema 영향 X)
--
-- 적용:
--   psql "$DATABASE_URL" -f frontend/server/db/migrations/002_better_auth_user_birthDate.sql

SET search_path TO auth;

-- 컬럼 추가 (재실행 안전)
ALTER TABLE "user"
    ADD COLUMN IF NOT EXISTS "birthDate" TEXT;

-- production user 0건 (Phase 4 pre-launch) 라 NOT NULL 직접 가능.
-- 운영 시점 사용자 존재 시: 별 cycle backfill + ALTER COLUMN SET NOT NULL.
-- 본 cycle 는 e2e/dev 환경 직접 NOT NULL 강제 — 가입 시 hook 이 검증.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM "user" WHERE "birthDate" IS NULL LIMIT 1) THEN
        RAISE NOTICE 'auth.user 에 birthDate IS NULL row 존재 — NOT NULL 강제 skip (별 cycle backfill 필요)';
    ELSE
        ALTER TABLE "user" ALTER COLUMN "birthDate" SET NOT NULL;
    END IF;
END $$;

COMMENT ON COLUMN "user"."birthDate"
    IS 'LEGAL-001 — ISO YYYY-MM-DD. 만 14세 미만 차단 검증 목적으로만 사용 (privacy.md §2.1 목적 한정). privacy.md §8 retention policy 준수.';
