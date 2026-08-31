# Mac self-hosted 배포 호스트 bootstrap

이 절차의 목표는 Mac 보유자가 호스트별 값만 채우고 기존 backend/frontend 배포 job을
`[self-hosted, terraworld]` runner에 연결하는 것이다. 배포 방식, 이미지 태그, 서비스별 태그,
롤백 방식은 바꾸지 않는다.

## 1. 경로 계약

두 배포 워크플로는 다음 순서로 배포 디렉터리를 정한다.

1. runner 프로세스 환경의 `TERRAWORLD_DEPLOY_DIR`
2. 변수가 아예 설정되지 않았으면 기존 호스트 경로(하위호환 폴백)

변수가 설정됐는데 빈 값·공백뿐인 값·상대 경로·`~` 경로·허용되지 않은 문자 경로이면 폴백하지
않고 실패한다. 선택된 경로가 실제 디렉터리이고 그 안에 `docker-compose.yml`이 있는지도 두
워크플로가 동일하게 검사한다.

새 Mac은 `<RUNNER_DIR>/.env`에 아래 한 줄을 둔다.

```text
TERRAWORLD_DEPLOY_DIR=<DEPLOY_DIR의 절대 경로>
```

`scripts/bootstrap-mac-host.sh --apply`가 이 파일 또는 키가 없을 때만 lock 아래에서 원자적으로
만든다. symlink·비정규 파일·중복 키·다른 값은 자동 수정하지 않는다. runner는 시작할 때
`<RUNNER_DIR>/.env`를 읽는다. 이 파일은 runner 프로세스용이며 로그인 셸에 export되지 않으므로,
운영 명령에서 `$TERRAWORLD_DEPLOY_DIR`가 자동으로 설정돼 있다고 가정하면 안 된다.

이미 실행 중인 서비스에 `.env` 변경이 필요하면 bootstrap은 서비스도 파일도 건드리지 않고
blocker로 종료한다. 운영자가 점검 후 서비스를 먼저 중지한 경우에만 다시 `--apply`를 실행해
파일 변경과 시작을 맡긴다. bootstrap 자체는 실행 중인 기존 서비스를 중지하지 않는다.

기본 macOS launchd 서비스를 쓸 때 생성되는 plist는
`$HOME/Library/LaunchAgents/<서비스명>.plist`에 있다. 정확한 서비스명은
`<RUNNER_DIR>/.service`에서 확인한다. 사용자 정의 launchd 서비스를 쓰는 경우에는 해당 plist의
`EnvironmentVariables`에도 `TERRAWORLD_DEPLOY_DIR`을 넣을 수 있지만, 이 문서는 runner 자체
`<RUNNER_DIR>/.env`를 우선 경로로 사용한다. GitHub runner의 `.env` 변경은 서비스 재시작 뒤
적용된다. 참고: [GitHub runner 서비스 구성](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application),
[runner `.env` 위치와 재시작 조건](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/run-scripts).

## 2. Mac 보유자가 실행할 순서

### 2.1 Docker Desktop과 deploy 저장소 준비

1. [Docker 공식 Mac 설치 문서](https://docs.docker.com/desktop/setup/install/mac-install/)에서
   실제 CPU에 맞는 Docker Desktop을 설치하고 다음 명령으로 한 번 실행한다. 설치 화면에서는
   CLI 도구를 `/usr/local/bin`에 연결하는 권장 설정을 사용한다. Apple Silicon Homebrew 경로
   `/opt/homebrew/bin`도 워크플로 PATH에 이미 포함되어 있다.

   ```bash
   open -a Docker
   ```

   Apple Silicon에서 Rosetta 2가 없으면 설치한다. 기존 backend amd64 이미지의 에뮬레이션 전제이며,
   Docker Desktop 설정에서도 x86_64/amd64용 Rosetta 사용이 활성화돼 있는지 확인한다.

   ```bash
   softwareupdate --install-rosetta
   ```

2. deploy 저장소를 최종 배포 경로에 checkout한다. 아래 `<DEPLOY_DIR>`은 symlink가 아닌
   절대 경로 사용을 권장한다.

```bash
git clone <DEPLOY_REPO_URL> "<DEPLOY_DIR>"
cd "<DEPLOY_DIR>"
test -e mac-host.env || cp mac-host.env.example mac-host.env
chmod 600 mac-host.env
vi mac-host.env
```

신규 호스트라 deploy `.env`가 없으면 `mac-host.env`의 `__FILL_...__` 값을 모두 채운다.
현재 운영 Mac처럼 `.env`가 이미 있으면 위쪽 `TERRAWORLD_*` 호스트 값 네 개만 채워도 되고,
compose 값 구간은 생성 입력으로 사용되지 않는다. 실제 값 파일은 권한 600이어야 하며, deploy
저장소 안의 `--config` 경로는 gitignore 대상만 허용된다. `mac-host.env.example`은 check 전용이라
`--apply`에 사용할 수 없다. 등록 토큰은 값 파일에 쓰지 않는다.

신규 `.env` 생성 payload에는 템플릿에 적힌 Compose 안전 문자만 사용한다. 공백, 따옴표, `$`,
백슬래시, `#`, 백틱이 필요한 값은 자동 생성하지 말고 권한 600의 `.env`를 직접 준비한다.

현재 운영 Mac에 `.env`가 이미 있으면 그대로 둔다. bootstrap은 기존 `.env`를 읽어 필수 키의
존재만 점검하고 절대 덮어쓰거나 병합하지 않는다.

### 2.2 host-local tunnel override 확인

다음 파일이 실제 배포 디렉터리에 있어야 한다.

```bash
test -f "<DEPLOY_DIR>/docker-compose.tunnel.yml"
echo $?
```

exit code 0이면 파일이 존재한다. 파일 내용과 요구 env 키는 아직 회수되지 않아 미확인이다.
bootstrap은 이 파일을 생성·복사·수정하지 않는다. 새 Mac으로 이전한다면 현재 배포 호스트에서
실제 파일을 안전하게 회수한 뒤 시크릿을 분리하고 배치해야 한다. 임의의 override를 만들면 안 된다.

### 2.3 GitHub Actions runner 다운로드와 등록

backend와 frontend 두 저장소가 같은 runner를 써야 하므로, 가능하면 GitHub 조직의
`Settings > Actions > Runners > New runner > New self-hosted runner`에서 조직 runner로 만든다.
runner group이 두 저장소를 모두 허용하는지도 확인한다. 저장소 runner만 허용되는 환경이면
backend/frontend마다 별도 runner 설치 디렉터리와 서비스를 등록해야 한다.

1. GitHub 화면에서 macOS와 실제 CPU 아키텍처(Apple Silicon이면 ARM64)를 선택한다.
2. 화면이 제시하는 최신 runner 다운로드·압축 해제 명령을 `<RUNNER_DIR>`에서 그대로 실행한다.
   버전과 다운로드 URL은 이 문서에 고정하지 않는다.
3. 같은 화면에서 1시간 내 만료되는 등록 토큰을 발급받는다.
4. 토큰이 프로세스 인자나 shell history에 남지 않도록 `--token` 인자를 생략하고 다음 대화형
   명령을 실행한 뒤, 요청될 때만 토큰을 붙여 넣는다.

```bash
cd "<RUNNER_DIR>"
./config.sh \
  --url "<GITHUB_ORG_OR_REPOSITORY_URL>" \
  --labels "terraworld" \
  --name "<RUNNER_NAME>" \
  --work "_work"
```

기본 라벨 `self-hosted`는 runner가 자동 부여하고, 위 명령이 사용자 라벨 `terraworld`를 추가한다.
기존 runner에 `config.sh`를 다시 실행해 라벨을 바꾸지 않는다. 기존 등록의 라벨이 빠졌다면 GitHub
Runners 화면에서 해당 runner를 열어 `terraworld`를 추가한다. 라벨은 대소문자를 구분하지 않지만
문서와 워크플로에는 소문자로 통일한다. 참고:
[runner 추가](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners),
[라벨 등록](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/apply-labels).

### 2.4 점검 후 적용

먼저 기본 check 모드를 실행한다. 이 모드는 영구 파일, 서비스, 컨테이너를 변경하지 않는다.

```bash
cd "<DEPLOY_DIR>"
bash scripts/bootstrap-mac-host.sh
echo $?
```

`[누락]`을 해결한 뒤에만 apply를 실행한다. apply는 먼저 전체 preflight를 끝내고 blocker가
하나라도 있으면 파일 변경과 서비스 설치·시작을 모두 건너뛴다.

```bash
cd "<DEPLOY_DIR>"
bash scripts/bootstrap-mac-host.sh --apply
echo $?
```

apply가 할 수 있는 변경은 다음으로 제한된다.

- deploy `.env`가 없고 `mac-host.env`의 필수 값이 모두 채워졌을 때 새로 생성(권한 600)
- `<RUNNER_DIR>/.env`가 없으면 원자적으로 생성, 있으면 lock 아래에서 임시 복사본에
  `TERRAWORLD_DEPLOY_DIR` 키 하나만 추가한 뒤 원자적으로 교체
- runner가 이미 등록되고 중지된 경우에만 macOS launchd 서비스를 마지막 단계에서 설치·시작

apply도 기존 deploy `.env`, 기존 runner 경로 키, 실행 중 runner 서비스,
`docker-compose.tunnel.yml`은 덮어쓰거나 중지하지 않는다.
Docker 설치, runner 패키지 다운로드, runner 등록, compose 기동은 자동화하지 않는다.

### 2.5 GitHub에서 연결 확인

GitHub의 조직 또는 저장소 `Settings > Actions > Runners`에서 다음을 확인한다.

- 상태: `Idle` 또는 job 수행 중이면 `Active`
- 라벨: `self-hosted`, `terraworld` 둘 다 존재
- runner group: backend와 frontend 저장소 모두 접근 허용

그다음 backend 또는 frontend의 CI workflow를 `main` 기준으로 수동 실행한다. CI와 이미지 push가
성공한 뒤 deploy job이 이 Mac에 배정된다. 배포 job은 `docker login`을 호출하지 않고 실행별 임시
`DOCKER_CONFIG`에 GHCR auth를 기록하며, `$HOME/.docker/cli-plugins`가 있으면 그 디렉터리를 임시
config에 symlink한다. 운영자의 기존 Docker config/keychain은 수정하지 않는다.

## 3. queued와 실패의 차이

`runs-on: [self-hosted, terraworld]`를 모두 만족하는 online/idle runner가 없으면 deploy job은
실패로 시작되는 것이 아니라 `Queued` 상태로 runner를 기다린다. 이 상태에는 실행된 step과 실패
로그가 없다. runner가 online이 되면 배정된다. GitHub의 현재 제한상 24시간 넘게 queued이면 그때
job이 실패한다. runner가 할당된 job을 60초 안에 받지 못하면 다시 queue로 돌아간다.

반대로 실패한 job은 runner가 job을 받아 `In progress`로 전환된 뒤 명령의 non-zero exit,
timeout 또는 health 판정 실패가 발생한 것이다. step 로그와 실패 위치가 남는다. 따라서 deploy가
queued이면 먼저 runner online/라벨/group을 보고, 시작 후 실패했다면 해당 step 로그를 본다.
참고: [self-hosted runner 라우팅과 queue 동작](https://docs.github.com/en/actions/reference/runners/self-hosted-runners).

## 4. 점검 계약과 운영 경계

bootstrap은 다음을 점검한다.

- macOS/Apple Silicon Rosetta, 워크플로 PATH의 Docker CLI, Docker daemon, Compose v2
- 임시 Docker config를 만들 수 있는 TMPDIR와 `$HOME/.docker/cli-plugins`
- 배포 디렉터리, `docker-compose.yml`, host-local `docker-compose.tunnel.yml`, `.env`
- base compose의 `tw-backend`, `tw-frontend` container name과 현재 컨테이너 존재 여부
- runner 디렉터리, 로컬 등록 파일, runner `.env`, launchd 서비스
- GitHub UI에서 확인해야 하는 `self-hosted`, `terraworld` 서버측 라벨

컨테이너가 아직 없는 것은 첫 배포 전에는 경고다. bootstrap이 compose를 기동하지 않는다. 기존
workflow가 컨테이너를 생성하고, backend는 최대 300초 동안 `tw-backend` health를 기다린다.
Apple Silicon에서 amd64 이미지를 Rosetta로 실행할 때 Spring 시작이 길어질 수 있다는 기존 예산을
그대로 유지한다. frontend는 `tw-frontend`를 기동한 뒤 공개되지 않은 로컬 로그인 경로의 HTTP 200을
기존 방식대로 확인한다.

## 5. 아직 해결되지 않은 것

`docker-compose.tunnel.yml`의 내용과 요구 env 키는 미확인이다. 따라서 이 문서와 값 템플릿만으로
완전히 새로운 호스트의 운영 토폴로지를 재구성할 수 있다고 주장하지 않는다. 현재 운영 호스트에
파일이 남아 있는 경우에는 M1 변경이 그 파일을 그대로 사용하므로 기존 배포 동작은 바뀌지 않는다.
회수·시크릿 분리·버전 관리 여부 결정은 `docs/TOPOLOGY-GAP.md`의 별도 작업이다.
