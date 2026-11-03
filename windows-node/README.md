# 윈도우 WAS 노드 (네이티브, Docker 없음)

HA 2노드 중 두 번째 커넥터. BIOS 가상화가 꺼져 있어 Docker 대신 이미지 산출물을 풀어 네이티브로 띄운다.
설계와 배경은 [../docs/ha-dual-node.md](../docs/ha-dual-node.md) 를 본다.

이 폴더는 노드 PC `C:\Users\jstop\terraworld-node\` 에 있는 스크립트의 사본이다(런타임·이미지·`app.env` 는 제외).
노드에서 고친 뒤 여기에 같이 반영한다.

## 구성

| 구성요소 | 포트(127.0.0.1) | 기동 스크립트 |
|---|---|---|
| redis | 6379 | `run-redis.ps1` |
| backend (ghcr 이미지의 `app.jar`, JDK 21) | 8080 | `run-backend.ps1` |
| frontend (ghcr 이미지의 `.output`, Node 20) | 3000 | `run-frontend.ps1` |
| nginx 1.28 (`nginx/terraworld.conf`) | 18090 | `run-nginx.ps1` |
| cloudflared `run terraworld` | — | 감시자가 직접 실행 |

- DB: Supabase(`terraworld-seoul`, session pooler). 접속 정보는 노드의 `app.env` 에만 있다.
- 외부로 직접 노출되는 포트는 없다. 트래픽은 Cloudflare 터널 → nginx 로만 들어온다.

## 프로세스 관리

- `supervisor.ps1`: 30초마다 각 포트에 **실제로 접속해 보고** 죽어 있으면 다시 띄운다. 작업 스케줄러 `TerraWorldNode` 가 S4U(로그인 없이)·부팅 시 실행한다.
  - 2026-10-29~31: 포트 확인에 `Get-NetTCPConnection` 을 쓰던 시절, S4U 세션에서 이 명령이 가끔 빈 결과를 돌려줬다. 그래서 멀쩡한 구성요소를 1분마다 중복 기동했고, nginx 가 600개 넘게 쌓였다. 중복 backend 는 Supabase pooler 의 연결 한도(15)까지 잡아먹었다. 지금은 TCP 접속으로 확인하고, nginx 는 프로세스가 없을 때만 띄운다.
- `autosync.sh`: `TerraWorldAutoSync` 작업이 5분마다 실행한다. ghcr `latest` digest 가 바뀌면 180초 대기한 뒤(Mac 먼저 반영) `sync-node.sh` 를 실행한다. 순서는 드레인 → 교체 → 로컬 검증 → 복귀이고, 실패하면 이전 버전으로 롤백한다.
- `install-boot-start.ps1`: 위 두 작업을 S4U·부팅 트리거로 등록한다(관리자, 1회).
- `restart-node-admin.ps1`: 관리자 권한으로 전체 재시작한다. S4U 로 뜬 프로세스는 일반 권한으로 종료할 수 없다.
- `stop-all.ps1`: 노드를 정지한다(Mac 단독 서빙으로 전환).

## 함정

- 이미지의 심볼릭 링크는 디렉터리 정션으로 복원된다. 그래서 `tmp-extract.py` 로 **최종 경로에 직접** 추출한다.
- frontend 의 `sharp` 는 linux 바이너리라 윈도우용 build/vendor 로 교체한다(`sync-node.sh`).
- node-pg 가 Supabase 인증서 체인을 거부하므로 `DATABASE_URL` 에 `uselibpqcompat=true&sslmode=require` 를 쓴다.
