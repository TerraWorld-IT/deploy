# better-auth 스키마 SQL (번들 사본)

`frontend/server/db/migrations/` 의 사본. 프로덕션 DB 최초 기동 시 backend Flyway V5
(교차 스키마 FK `public.users → auth."user"`)보다 **먼저** 적용되어야 한다.
`scripts/bootstrap.sh` 가 postgres 기동 직후 이 파일들을 적용한다.

⚠️ frontend 원본이 SoT다. 원본이 바뀌면 여기도 손으로 맞춰야 한다.

---

## 체크섬 가드 (`CHECKSUMS.txt`)

`CHECKSUMS.txt` 는 이 디렉토리 SQL 파일들의 sha256 목록이고, CI(`.github/workflows/ci.yml`
의 `sql-checksums` job)가 매 push/PR 마다 재계산해 대조한다.

### 이 가드가 증명하는 것 / 못 하는 것

- ✅ **증명함 — 로컬 무결성**: 이 디렉토리의 SQL 이 매니페스트 기록 이후 바뀌지 않았다.
  즉 "deploy 사본만 슬쩍 손댔다"를 잡는다. 파일 추가/삭제도 개수 대조로 잡는다.
- ❌ **증명 못 함 — cross-repo 동일성**: frontend 원본과 같은지는 **전혀 모른다.**
  이 repo 의 CI 는 private 인 frontend repo 를 PAT 없이 checkout 할 수 없어서
  원본을 읽지 못한다. 즉 **frontend 쪽만 바뀌고 여기가 그대로면 CI 는 초록색이다.**
  그 경우 drift 는 프로덕션 최초 기동 때 Flyway V5 의 FK 실패로 드러난다.

따라서 **frontend 마이그레이션이 바뀔 때마다 아래 대조를 사람이 직접 돌려야 한다.**

### cross-repo 동일성 수동 확인

워크스페이스 루트(`deploy/` 와 `frontend/` 의 부모)에서:

```bash
diff -r --exclude=README.md --exclude=CHECKSUMS.txt \
  deploy/db/auth frontend/server/db/migrations && echo "동일 (cross-repo OK)"
```

- exit 0 + `동일` 출력 → 두 사본이 바이트 단위로 같다.
- exit 1 → 내용이 다르거나 한쪽에만 있는 파일이 있다 (`Only in ...` 줄 확인).
- exit 2 → 경로가 없다. **이때는 "같다"가 아니라 "확인 실패"다** — 경로를 고쳐 다시 돌린다.

`&& echo` 형태라 경로를 잘못 줘도 성공 메시지가 뜨지 않는다(빈 출력끼리 비교해 통과하는
함정이 없다). 반드시 `동일` 문구가 눈에 보여야 통과로 친다.

### 원본이 바뀌어 사본을 갱신했을 때

1. `frontend/server/db/migrations/` 의 파일을 이 디렉토리로 복사
2. 위 `diff -r` 로 동일 확인
3. 매니페스트 재생성:

   ```bash
   cd deploy/db/auth
   sha256sum *.sql | sed 's/ \*/  /' > CHECKSUMS.txt
   ```

   `sed` 는 Windows Git Bash 의 binary 모드 표기(` *파일명`)를 Linux 와 같은 두 칸 공백으로
   맞춘다. 안 맞춰도 `sha256sum -c` 는 통과하지만 diff 노이즈가 생긴다.
4. SQL 과 `CHECKSUMS.txt` 를 **같은 커밋**에 담는다. 따로 커밋하면 그 사이 커밋의 CI 가 깨진다.

### 로컬에서 가드 돌려보기

```bash
cd deploy/db/auth && sha256sum -c CHECKSUMS.txt
```

### 줄바꿈(CRLF) 주의 — 매니페스트가 깨지는 유일한 현실적 경로

이 SQL 3개는 **CRLF 로 커밋되어 있다**(모든 줄. `git cat-file blob HEAD:db/auth/001_better_auth_init.sql`
로 실측). 이 repo 는 `core.autocrlf=false` 이고 `.gitattributes` 도 없어서 git 이 체크아웃/커밋
어느 방향으로도 줄바꿈을 변환하지 않는다 — 그래서 Windows 든 Linux CI 든 **바이트가 동일**하고
매니페스트가 양쪽에서 그대로 통과한다.

⚠️ 깨지는 경우는 반대다. 누군가 **줄바꿈 정규화를 도입하면** blob 이 LF 로 다시 쓰이면서
sha256 3개가 **전부** 바뀐다. 대표적인 트리거:

- `.gitattributes` 에 `* text=auto` (또는 `*.sql text`) 추가
- `core.autocrlf=true` 로 설정한 클론에서 이 파일들을 다시 커밋
- 에디터가 저장하며 LF 로 변환

그 경우 CI 는 `FAILED` 로 정상 검출된다. 대응은 정규화를 되돌리는 것이 아니라, 정규화된
내용으로 **매니페스트를 재생성해 같은 커밋에 담는 것**이다(위 "원본이 바뀌어 사본을 갱신했을 때" 3~4단계).
단 이때 `frontend/server/db/migrations/` 원본도 같은 줄바꿈이어야 cross-repo `diff -r` 이 통과한다.
