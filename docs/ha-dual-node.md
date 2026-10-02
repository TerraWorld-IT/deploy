# HA 이중화 — WAS 2노드 (Mac + 윈도우) 설계·가이드

목표: **한 노드가 내려가도 같은 URL(`https://terraworld.web-qplay.kr`)로 서비스가 계속 응답**한다.

요약: Cloudflare Tunnel 은 **하나의 named tunnel 에 여러 cloudflared 복제본(connector)** 을 붙이면
자동으로 트래픽을 분산하고, 한 커넥터가 끊기면 남은 커넥터로 **자동 failover** 한다(Cloudflare 측 기능,
추가 LB 비용 없음). 따라서 WAS(프론트/백엔드/nginx) 계층 이중화는 두 번째 머신에서 같은 스택 +
**같은 터널 자격증명의 두 번째 cloudflared** 를 띄우면 끝난다.

```
                 ┌──────────────── Cloudflare Edge ────────────────┐
  사용자 ──TLS──▶ │   terraworld.web-qplay.kr  (named tunnel)        │
                 │     auto load-balance / failover across conns    │
                 └───────┬───────────────────────────────┬─────────┘
                         │ cloudflared(연결1)             │ cloudflared(연결2)
                    ┌────▼─────┐                     ┌────▼──────┐
                    │  Mac     │                     │  윈도우    │
                    │ nginx-tunnel:18090            │ nginx-tunnel:18090
                    │  ├ frontend:3000              │  ├ frontend:3000
                    │  └ backend:8080               │  └ backend:8080
                    └────┬─────┘                     └────┬──────┘
                         └──────────► 공유 DB ◄───────────┘
                                 (아래 "DB 함정" 참고)
```

- 터널 이름: `terraworld`
- 터널 UUID: `b50176a7-1943-4413-a050-9ac030eeb966`
- 자격증명 파일: `~/.cloudflared/b50176a7-1943-4413-a050-9ac030eeb966.json` (Mac 에 있음)
- ingress: `terraworld.web-qplay.kr → http://localhost:18090` (각 노드의 로컬 nginx-tunnel)
- 이미지: `ghcr.io/terraworld-it/terraworld-{backend,frontend}:latest` (**private 패키지** → ghcr 인증 필요)
- backend 이미지는 `linux/amd64` → **윈도우(amd64)에서 네이티브** 실행(Mac Rosetta 보다 빠름)

---

## ⚠️ DB 함정 — 반드시 먼저 결정

WAS 2노드는 쉽지만, **"한쪽이 죽어도 서비스"가 실제로 성립하려면 DB 가 죽는 노드와 분리돼야 한다.**

- 현재 DB(`tw-postgres`)는 **Mac 안**에 있다. 이 상태로 윈도우 WAS 만 추가하면:
  - 윈도우가 죽을 때 → Mac 이 서비스(OK)
  - **Mac 이 죽을 때 → DB 도 같이 죽어** 윈도우 WAS 도 데이터를 못 읽는다(목표 미달성).
- 그리고 두 노드가 **각자 자기 DB** 를 쓰면 접속한 노드에 따라 데이터가 달라져(계정/재화/기록 갈림) 못 쓴다.

### DB 선택지

| 구성 | Mac 다운 시 | 윈도우 다운 시 | 난이도 | 비고 |
|------|------------|---------------|--------|------|
| **D0. DB=Mac, 윈도우는 WAS 만** | ❌ DB 동반 다운 | ✅ | 낮음 | "업데이트/재부팅 중 무중단" 정도만 커버(계획된 다운) |
| **D1. 매니지드 DB(권장)** | ✅ | ✅ | 중간 | Neon/Supabase/RDS 로 이전 → 두 WAS 가 공유. **진짜 HA** |
| **D2. 제3의 상시 호스트에 DB** | ✅ | ✅ | 중간 | 별도 상시 장비 필요 |

**권장 경로**: 지금은 **D0 로 WAS 이중화부터 구축**(계획된 재부팅/배포/업데이트 중 무중단 확보) →
이후 **D1(매니지드 DB)로 전환**해 완전 HA. D1 전환 시 두 노드의 `.env` 의 DB 접속 문자열만
매니지드 엔드포인트로 바꾸면 된다.

> 참고: D0 라도 "매일 새벽 2시 클린"이나 수동 재부팅, 배포 교체 같은 **계획된 다운타임**에는
> 윈도우 노드가 받아줘서 체감 안정성이 오른다. 급작스런 Mac 전체 장애까지 커버하려면 D1 필요.

---

## 윈도우 노드 구축 절차 (D0 기준)

### 0. 사전 준비 (사용자가 직접)
- 윈도우에 **Docker Desktop**(WSL2 백엔드) 설치 + 실행
- `git`, (선택) `gh` 설치
- Mac 에서 아래 2개를 윈도우로 안전하게 복사:
  - 터널 자격증명: `~/.cloudflared/b50176a7-1943-4413-a050-9ac030eeb966.json`
  - 배포 시크릿: `deploy/.env` (운영 값 그대로)

### 1. deploy 레포 체크아웃
```powershell
git clone https://github.com/TerraWorld-IT/deploy.git
cd deploy
# 복사해 온 .env 를 deploy/.env 로 배치
```

### 2. ghcr 로그인 (private 이미지 pull)
`read:packages` 권한 PAT 로:
```powershell
echo <GHCR_PAT> | docker login ghcr.io -u <github-id> --password-stdin
```

### 3. WAS 스택만 기동 (postgres/redis 는 공유 DB 사용 시 로컬 미기동)
- D0: 윈도우는 **frontend/backend/nginx-tunnel 만** 띄우고, `.env` 의
  `SPRING_DATASOURCE_URL` / `DATABASE_URL` 을 **Mac 의 Postgres 를 가리키도록** 바꾼다.
  - Mac Postgres 를 윈도우에서 접근하게 하려면: 같은 LAN 이면 Mac IP:5432 개방,
    원격이면 cloudflared TCP 또는 Tailscale 로 사설 연결(권장). 평문 인터넷 노출 금지.
- D1(매니지드)로 갈 거면 이 단계에서 바로 매니지드 DB 접속 문자열을 넣는다.
```powershell
docker compose -f docker-compose.yml -f docker-compose.tunnel.yml up -d backend frontend nginx-tunnel
```

### 4. 두 번째 cloudflared 복제본 (핵심)
`~/.cloudflared/config.yml` (윈도우):
```yaml
tunnel: b50176a7-1943-4413-a050-9ac030eeb966
credentials-file: C:\Users\<you>\.cloudflared\b50176a7-1943-4413-a050-9ac030eeb966.json
ingress:
  - hostname: terraworld.web-qplay.kr
    service: http://localhost:18090
  - service: http_status:404
```
```powershell
cloudflared tunnel run terraworld
# 서비스로 상시화: cloudflared service install (관리자 PowerShell)
```

### 5. 검증
- `cloudflared tunnel info terraworld` → **커넥터 2개**(darwin + windows) 보이면 성공.
- 윈도우 로컬: `curl http://localhost:18090/ -H "Host: terraworld.web-qplay.kr"` → 302
- 외부: `https://terraworld.web-qplay.kr/` 가 두 노드 중 하나로 응답. Mac 의 cloudflared 를
  잠깐 멈춰도 사이트가 계속 뜨면 failover 동작 확인.

---

## 운영 메모
- **배포 일관성**: 지금 배포는 Mac self-hosted 러너가 `compose pull/up` 한다(또는 중앙 `deploy.yml`).
  2노드가 되면 **두 노드 모두** 새 이미지를 pull/재기동해야 버전이 안 어긋난다.
  중앙 배포 워크플로(`deploy.yml`)를 양 노드 러너로 fan-out 하거나, 윈도우에도 self-hosted 러너를 붙인다.
- **cloudflared 버전**: 두 노드 cloudflared 버전을 비슷하게 유지.
- **nginx-tunnel 포트(18090)**: 두 노드 각자 로컬에서만 열면 되고 외부 노출 불필요(cloudflared 가 종단).
- **세션/Redis**: better-auth 세션은 DB(공유)에 저장되므로 노드 간 세션 공유 OK. Redis 캐시는
  노드별 로컬이어도 기능 동작(캐시 미스만 증가).

## 후속(완전 HA, D1)
1. 매니지드 Postgres 생성 → 현재 DB 덤프 이전(`pg_dump`/`pg_restore`).
2. 두 노드 `.env` 의 DB 접속 문자열을 매니지드 엔드포인트로 교체 → 재기동.
3. Mac/윈도우 어느 쪽이 죽어도 생존 노드 + 매니지드 DB 로 서비스 지속.
