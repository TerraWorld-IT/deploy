# better-auth 스키마 SQL (번들 사본)

`frontend/server/db/migrations/` 의 사본. 프로덕션 DB 최초 기동 시 backend Flyway V5
(교차 스키마 FK `public.users → auth."user"`)보다 **먼저** 적용되어야 한다.
`scripts/bootstrap.sh` 가 postgres 기동 직후 이 파일들을 적용한다.

⚠️ frontend 원본이 바뀌면 여기도 동기화 필요(현재 수동). 원본이 SoT.
