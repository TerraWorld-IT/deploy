# ⚠️ 미해결: 실 프로덕션 compose override 가 버전 관리 밖에 있다 (TOPO-1)

**상태**: OPEN — **이 repo 의 인프라 변경 작업 전 반드시 먼저 처리해야 하는 선행 조건**
**영향 범위**: deploy repo 전체 (여기서 고친 compose 설정이 프로덕션에 닿지 않을 수 있음)

---

## 무슨 일인가

frontend / backend 두 repo 의 배포 job 이 **둘 다** 같은 override 파일을 얹어서 스택을 띄운다.

```bash
# 경로 선택/검증: backend/.github/workflows/ci.yml:161-184
# 경로 선택/검증: frontend/.github/workflows/ci.yml:192-215
# 실제 deploy: backend/.github/workflows/ci.yml:200-202
# 실제 deploy: frontend/.github/workflows/ci.yml:240,252-253
# 미설정이면 기존 경로, 설정됐으면 절대 경로·디렉터리·base compose를 검증
DEPLOY="<검증을 통과한 실제 절대 경로>"
cd "$DEPLOY"
docker compose -f docker-compose.yml -f docker-compose.tunnel.yml pull   <서비스>
docker compose -f docker-compose.yml -f docker-compose.tunnel.yml up -d --no-deps <서비스>
```

그런데 `docker-compose.tunnel.yml` 은 **이 repo 에 없다.** 워크스페이스 어디에도 없다.

```bash
# 워크스페이스 루트에서 (2026-07-29 실측)
find . -name docker-compose.tunnel.yml     # 출력 없음
cd deploy && git ls-files | grep tunnel    # 출력 없음
```

즉 그 파일은 배포 호스트에서 검증된 실제 배포 절대 경로의 로컬 디스크에만 있고,
백업도 없고, 무엇이 들어 있는지 아무도 확인할 수 없다.

## 왜 이게 중요한가

`docker compose -f a.yml -f b.yml` 은 **뒤 파일이 앞 파일을 덮어쓴다.** 따라서
`docker-compose.tunnel.yml` 은 이 repo 의 `docker-compose.yml` 이 정의한 거의 모든 것
— 포트 매핑, 네트워크, nginx 노출 여부, 서비스 환경변수 — 을 조용히 바꿀 수 있다.

결과적으로:

1. **이 repo 의 `docker-compose.yml` 은 프로덕션의 SoT 가 아니다.** 여기서 무언가를
   고쳐도 override 가 같은 키를 덮고 있으면 프로덕션 동작은 안 바뀐다. 반대로 무해해
   보이는 변경이 override 와 충돌해 배포를 깨뜨릴 수도 있다.
2. **문서와 실제가 다르다.** `docs/production-setup.md` 는 nginx + certbot(80/443 직접
   노출) 모델을 기술하지만, 실제 진입 경로는 Cloudflare Tunnel 로 보인다. 두 모델은
   TLS 종료 지점과 클라이언트 IP 전달 방식이 달라, 예컨대 rate-limit 의
   `X-Forwarded-For` 신뢰 설정이 문서 기준으로는 틀린 판단이 될 수 있다.
3. **그 호스트가 죽으면 토폴로지 복구 방법이 없다.** DR 런북(`docs/dr-runbook.md`)은
   DB/Redis 복구는 다루지만, 애초에 스택을 어떻게 띄웠는지를 재현할 수 없다.
4. **이 repo 에 CI 게이트를 붙여도 반쪽이다.** `.github/workflows/ci.yml` 의 compose
   해석 검증은 tracked 파일만 본다. 실 프로덕션 조합(`base + tunnel`)은 검증 대상 밖이다.

## 해야 할 일 (순서대로)

1. 배포 호스트에서 파일을 회수한다:

   ```bash
   ssh <배포호스트>
   # mac-host.env의 TERRAWORLD_DEPLOY_DIR 값을 확인해 아래 경로 자체를 실제 절대 경로로 바꾼다.
   # runner .env는 로그인 셸에 export되지 않으므로 $TERRAWORLD_DEPLOY_DIR를 사용하지 않는다.
   cat "/absolute/path/to/terraworld-deploy/docker-compose.tunnel.yml"
   ```

2. 내용에 시크릿(토큰·터널 자격증명 등)이 있는지 확인한다.
   - 없으면 → 그대로 이 repo 에 커밋.
   - 있으면 → 값은 `.env` 로 빼고(`${TUNNEL_TOKEN}` 형태) 파일 구조만 커밋.
     `.env` 는 이미 `.gitignore` 대상이고 `SECRETS.md` 에 행을 추가한다.
3. `docs/production-setup.md` 의 nginx/certbot 서술을 실제 토폴로지에 맞게 정정한다.
   (현재 서술이 실제와 다르다는 사실 자체를 그 문서에도 남길 것.)
4. `.github/workflows/ci.yml` 의 compose 해석 검증에 **실 프로덕션 조합**을 추가한다:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.tunnel.yml config --quiet
   ```

5. 위 4단계가 끝나기 전까지 — **이 repo 의 compose/nginx 를 고치는 작업은
   "프로덕션에 반영된다"고 가정하지 말 것.** 반영 여부를 실제 응답으로 확인해야 한다.

## 하지 말아야 할 것

**파일 내용을 추측해서 만들어 넣지 말 것.** 실제 파일이 무엇을 덮고 있는지 모르는 상태에서
그럴듯한 `docker-compose.tunnel.yml` 을 새로 작성해 커밋하면, 다음 배포에서 그 추측이
호스트의 진짜 파일을 덮어써(또는 어긋나) 프로덕션을 끊을 수 있다. 부재보다 나쁘다.
회수가 유일한 출발점이다.
