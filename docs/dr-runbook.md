# Disaster Recovery Runbook — TerraWorld

> **UltraPlan v3 O-DR-001 (2026-05-18, HIGH)** — Codex post-audit 격상
> PostgreSQL 16 backup + Redis 7 persistence + 복구 절차
> 작성: 2026-05-18, 시행 권장: Phase 4 production deploy 전
>
> **2026-06-23 (P3-4 실배선)**: 본 runbook 의 인라인 백업 스크립트를 실 파일로 배선 완료 —
> [`deploy/scripts/pg-backup.sh`](../scripts/pg-backup.sh), [`deploy/scripts/redis-backup.sh`](../scripts/redis-backup.sh),
> cron 등록 [`deploy/scripts/crontab.terraworld-backup`](../scripts/crontab.terraworld-backup).
> 스크립트는 env 미설정 시 graceful skip(S3/GPG/Discord). **실 실행 + §6 DR drill 은 운영 배포 시(인간 게이트).**

---

## 1. 목표 RPO / RTO

| 지표 | 목표 | 비고 |
| --- | --- | --- |
| RPO (Recovery Point Objective) | **15분** | PostgreSQL WAL streaming + S3/R2 archive |
| RTO (Recovery Time Objective) | **2시간** | full restore + Redis warm-up |
| backup 보관 | **30일** (daily) + **12개월** (weekly) | S3/R2 lifecycle |

## 2. PostgreSQL 16 backup

### 2.1 자동 backup (cron)

```bash
# /etc/cron.d/postgres-backup
# 매일 03:00 KST (UTC 18:00 전날)
0 18 * * * postgres /opt/terraworld/deploy/scripts/pg-backup.sh
```

`deploy/scripts/pg-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

DATE=$(date +%Y%m%d-%H%M)
BACKUP_DIR=/var/backups/postgres
S3_BUCKET=terraworld-backup
RETENTION_DAYS=7  # local

mkdir -p "$BACKUP_DIR"

# 1) pg_dump (custom format — fast restore + selective)
pg_dump -Fc -d terraworld -f "$BACKUP_DIR/terraworld-$DATE.dump"

# 2) gzip + encrypt (GPG public key)
gzip "$BACKUP_DIR/terraworld-$DATE.dump"
gpg --encrypt --recipient backup@terraworld.app \
    --output "$BACKUP_DIR/terraworld-$DATE.dump.gz.gpg" \
    "$BACKUP_DIR/terraworld-$DATE.dump.gz"
rm "$BACKUP_DIR/terraworld-$DATE.dump.gz"

# 3) S3/R2 upload (with lifecycle policy)
aws s3 cp "$BACKUP_DIR/terraworld-$DATE.dump.gz.gpg" \
    "s3://$S3_BUCKET/postgres/daily/"

# 4) local retention (7일)
find "$BACKUP_DIR" -name "terraworld-*.dump.gz.gpg" -mtime +$RETENTION_DAYS -delete

# 5) Discord webhook 알림
curl -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"✅ pg backup ok: $DATE\"}"
```

### 2.2 WAL streaming (point-in-time recovery)

`postgresql.conf`:

```ini
wal_level = replica
archive_mode = on
archive_command = 'aws s3 cp %p s3://terraworld-backup/postgres/wal/%f'
archive_timeout = 900  # 15분
```

### 2.3 복구 절차

```bash
# 1) S3 에서 latest dump + WAL 다운로드
LATEST=$(aws s3 ls s3://terraworld-backup/postgres/daily/ | tail -1 | awk '{print $4}')
aws s3 cp "s3://terraworld-backup/postgres/daily/$LATEST" /tmp/

# 2) decrypt + restore
gpg --decrypt /tmp/$LATEST | gunzip > /tmp/restore.dump
pg_restore -d terraworld --clean --if-exists /tmp/restore.dump

# 3) point-in-time recovery (WAL replay)
# postgresql.conf 의 restore_command 설정 + recovery.signal 생성 후 재시작
```

## 3. Redis 7 persistence

### 3.1 설정

`redis.conf`:

```ini
# AOF (Append-Only File) — 매 write 마다 fsync
appendonly yes
appendfsync everysec   # 1초 buffer (data loss <1s)

# RDB snapshot — backup 용
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
dir /var/lib/redis/
```

### 3.2 backup (별 cron)

```bash
# /opt/terraworld/deploy/scripts/redis-backup.sh
# Redis CLI 로 BGSAVE 트리거 + RDB 파일 S3 업로드
redis-cli BGSAVE
sleep 5
aws s3 cp /var/lib/redis/dump.rdb s3://terraworld-backup/redis/$(date +%Y%m%d).rdb
```

### 3.3 복구

```bash
# Redis 중단 → RDB 복원 → 재시작
systemctl stop redis
aws s3 cp s3://terraworld-backup/redis/YYYYMMDD.rdb /var/lib/redis/dump.rdb
chown redis:redis /var/lib/redis/dump.rdb
systemctl start redis

# AOF 동시 사용 시 — AOF rewrite 후 RDB load
redis-cli BGREWRITEAOF
```

> ⚠️ Redis 는 rate limit + 광고 카운터 외 비휘발성 데이터 없음 — 복구 시 1일 손실 허용.
> 더 엄격한 SLA 필요 시 Redis Sentinel 또는 Cluster (Production 규모 따라 Phase 5+).

## 4. R2 (Cloudflare) 이미지 backup

Phase 4 진입 후 R2 bucket 활성화 시 (사용자 #4 보류 해제 후):

- Cloudflare R2 의 **Replication** 또는 자체 S3 lifecycle policy 활용
- 사용자 사진 → daily snapshot → 별 region 보관

## 5. 재해 시나리오별 절차

### 5.1 PostgreSQL primary 디스크 손상

1. Read replica 가 있는 경우 — failover (Patroni / pg_auto_failover)
2. 없는 경우 — §2.3 절차로 latest dump + WAL replay (RTO ~2h)

### 5.2 R2 bucket 손실

1. S3 backup 으로 restore (lifecycle 정책 미적용 region)
2. user 가 재업로드 권장 (메모 / 알림 발송)

### 5.3 전체 region outage

1. Cloudflare 의 multi-region failover (R2 가 자동)
2. Production server 별 region 배포 (Phase 5+ 검토)

## 6. 검증 (월 1회 drill)

- [ ] 별 환경에 latest dump restore → CRUD smoke test
- [ ] Redis RDB load → key 카운트 확인
- [ ] Discord webhook 알림 동작
- [ ] S3 lifecycle policy 적용 확인 (30일 / 12개월 transition)

## 7. References

- UltraPlan v3 O-DR-001 (HIGH, Codex post-audit 격상)
- 통합 기획서 §11.3 외부 의존성 (E-DNS-001 Production 서버)
