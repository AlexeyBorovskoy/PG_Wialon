# PG_Wialon

Полный репозиторий **от 0 до полного запуска** PostgreSQL для Wialon IPS (IRZ Bus).

Этот проект теперь оформлен как пошаговый production-пайплайн:

1. Создание роли и базы данных.
2. Создание схемы и таблиц с нуля.
3. Создание ограничений, индексов и дедупликации.
4. Подключение авто-парсинга `#SD#` через trigger.
5. Настройка ретенции и ежедневной очистки.
6. Назначение безопасных прав приложению.
7. Smoke-test и запуск в эксплуатацию.
8. Сетевое ужесточение (UFW) для безопасной работы.

---

## 1. Цели проекта

`PG_Wialon` покрывает полный жизненный цикл БД для приема Wialon IPS:

- raw хранение всех кадров (`#L#`, `#SD#`, `#B#`, `#P#`, произвольные строки)
- нормализованный слой наблюдений Wi-Fi
- событийный слой (`appeared/disappeared`)
- идемпотентность обработки
- ретенция
- безопасные grants
- эксплуатационные скрипты для запуска и поддержки

Проект рассчитан на PostgreSQL 13+ (проверено на PostgreSQL 16).

---

## 2. Структура репозитория

```
PG_wialon/
├── sql/
│   ├── 001_schema.sql
│   ├── 002_constraints_indexes.sql
│   ├── 003_sd_parser_trigger.sql
│   ├── 004_retention.sql
│   ├── 005_grants.sql
│   └── 006_smoke_test.sql
├── scripts/
│   ├── bootstrap_from_zero.sh
│   └── install_retention_cron.sh
├── ops/
│   └── ufw_hardening.sh
├── 001_init_raw.sql
├── 002_parsed_sd.sql
├── 003_wifi_events.sql
├── 004_retention.sql
├── 005_grants.sql
├── 006_finalize_wialon_db.sql
├── 007_finalize_fix.sql
└── wialon-retention.cron
```

Важно:
- **Основной актуальный путь** — это `sql/` + `scripts/`.
- Файлы `001..007` в корне оставлены как исторические артефакты этапа доработки уже существующей БД.

---

## 3. Протокол Wialon (входной контракт)

### 3.1 Login кадр

```
#L#IMEI,PASSWORD
```

### 3.2 Data кадр

```
#SD#TIMESTAMP,LAT,LON,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-55;wifi_chan:6;wifi_event:appeared
```

### 3.3 Дополнительные кадры

- `#B#...`
- `#P#...`
- любые произвольные строки

Все строки фиксируются в raw таблице `wialon.ips_frames`.

---

## 4. Модель данных (с нуля)

## 4.1 `wialon.ips_frames`

Raw слой, где хранится все входящее:
- `id BIGSERIAL`
- `received_at TIMESTAMPTZ`
- `remote_addr TEXT`
- `imei TEXT`
- `frame_type TEXT`
- `frame TEXT`

## 4.2 `wialon.allowlist`

Управляемый список разрешенных BSSID для prod-режимов:
- `bssid TEXT PRIMARY KEY`
- `channel_2g SMALLINT`
- `enabled BOOLEAN`
- `updated_at TIMESTAMPTZ`

## 4.3 `wialon.observations`

Нормализованный слой наблюдений, формируется из `#SD#`:
- `frame_ts`
- `bssid`
- `rssi_dbm`
- `chan`
- `raw_frame_id` (FK на `ips_frames`)
- `extra JSONB` (lat/lon/wifi_event и т.д.)

## 4.4 `wialon.events`

Событийный слой:
- `event_type` = `appeared|disappeared`
- `event_ts`
- `imei`
- `bssid`
- `source`
- ссылки на observation/raw
- `details JSONB`

## 4.5 `wialon.retention_policy`

Настраиваемые интервалы хранения по таблицам.

---

## 5. Порядок запуска с нуля

## 5.1 Предусловия

На хосте PostgreSQL должны быть доступны:
- superuser/админ доступ к кластеру
- `psql`
- сеть до PostgreSQL

## 5.2 Автоматический запуск (рекомендуется)

```bash
cd /path/to/PG_wialon
DB_PASSWORD='your_strong_password' ./scripts/bootstrap_from_zero.sh
```

Скрипт делает:
1. Проверяет/создает роль `wialon_wifi`.
2. Проверяет/создает базу `wialon_wifi`.
3. Применяет миграции `sql/001..005`.
4. Выполняет smoke-test (`sql/006_smoke_test.sql`) в транзакции с rollback.

Опциональные env:
- `DB_NAME` (default `wialon_wifi`)
- `DB_USER` (default `wialon_wifi`)
- `PGHOST` (default `127.0.0.1`)
- `PGPORT` (default `5432`)
- `PG_SUPERUSER` (default `postgres`)

## 5.3 Ручной запуск (если нужен полный контроль)

```bash
# 1) создать роль/БД вручную
psql -U postgres -d postgres -c "CREATE ROLE wialon_wifi LOGIN PASSWORD '***';"
psql -U postgres -d postgres -c "CREATE DATABASE wialon_wifi OWNER wialon_wifi;"

# 2) применить миграции
psql -v ON_ERROR_STOP=1 -U postgres -d wialon_wifi -f sql/001_schema.sql
psql -v ON_ERROR_STOP=1 -U postgres -d wialon_wifi -f sql/002_constraints_indexes.sql
psql -v ON_ERROR_STOP=1 -U postgres -d wialon_wifi -f sql/003_sd_parser_trigger.sql
psql -v ON_ERROR_STOP=1 -U postgres -d wialon_wifi -f sql/004_retention.sql
psql -v ON_ERROR_STOP=1 -U postgres -d wialon_wifi -f sql/005_grants.sql

# 3) smoke-test
psql -U postgres -d wialon_wifi -f sql/006_smoke_test.sql
```

---

## 6. Что делают миграции `sql/001..005`

## `sql/001_schema.sql`
- создает схему `wialon`
- создает таблицы `ips_frames`, `allowlist`, `observations`, `events`, `retention_policy`

## `sql/002_constraints_indexes.sql`
- FK `observations.raw_frame_id -> ips_frames.id`
- check-constraint `events.event_type`
- индексы под запросы по времени и IMEI/BSSID
- уникальные индексы дедупа observations/events

## `sql/003_sd_parser_trigger.sql`
- функция `wialon.trg_parse_sd_from_raw()`
- AFTER INSERT trigger на `wialon.ips_frames`
- автоматический парсинг `#SD#` в `observations`
- автоматическая генерация `appeared/disappeared` в `events`
- fallback времени события на `received_at`

## `sql/004_retention.sql`
- наполняет `retention_policy`
- создает `wialon.run_retention(now())`
- политики по умолчанию:
  - `ips_frames`: 30 days
  - `observations`: 90 days
  - `events`: 180 days

## `sql/005_grants.sql`
- выдает безопасные права роли `wialon_wifi`
- права на схему/таблицы/sequence
- EXECUTE на `run_retention()` и parser function

---

## 7. Автопарсинг `#SD#` (как работает)

При вставке кадра в raw:

```sql
INSERT INTO wialon.ips_frames (... frame_type='sd', frame='#SD#...');
```

триггер делает:
1. regex-парсинг payload.
2. извлекает `timestamp`, `lat/lon`, `wifi_bssid`, `wifi_rssi`, `wifi_chan`, `wifi_event`.
3. пишет `wialon.observations` с `raw_frame_id`.
4. если `wifi_event in (appeared, disappeared)` — пишет `wialon.events`.
5. применяет `ON CONFLICT DO NOTHING` для идемпотентности.

Если парсинг не удался, raw-кадр сохраняется, ingestion не падает.

---

## 8. Ретенция и обслуживание

## 8.1 Проверка вручную

```sql
SELECT * FROM wialon.run_retention(now());
```

## 8.2 Установка daily cron

```bash
sudo ./scripts/install_retention_cron.sh
```

Скрипт установит `/etc/cron.daily/wialon-retention` и выполнит пробный запуск.

---

## 9. Запросы для контроля

## 9.1 Последние raw кадры

```sql
SELECT id, received_at, remote_addr, imei, frame_type, frame
FROM wialon.ips_frames
ORDER BY id DESC
LIMIT 50;
```

## 9.2 Последние observations по IMEI

```sql
SELECT id, raw_frame_id, imei, bssid, frame_ts, rssi_dbm, chan, extra
FROM wialon.observations
WHERE imei = '865546046250136'
ORDER BY frame_ts DESC, id DESC
LIMIT 50;
```

## 9.3 События по BSSID за период

```sql
SELECT id, event_ts, imei, bssid, event_type, source, raw_last_id
FROM wialon.events
WHERE bssid = 'AA:BB:CC:DD:EE:FF'
  AND event_ts >= now() - interval '7 days'
ORDER BY event_ts DESC, id DESC;
```

## 9.4 Последний статус по BSSID

```sql
SELECT DISTINCT ON (bssid)
  bssid,
  imei,
  event_type AS last_event_type,
  event_ts   AS last_event_ts,
  source
FROM wialon.events
ORDER BY bssid, event_ts DESC, id DESC;
```

---

## 10. Полный запуск в проде (runbook)

1. Поднять PostgreSQL.
2. Выполнить `bootstrap_from_zero.sh`.
3. Настроить receiver service и env.
4. Проверить прием login и sd кадров.
5. Проверить заполнение `observations/events`.
6. Установить retention cron.
7. Ужесточить UFW.
8. Провести final smoke-test и зафиксировать baseline.

---

## 11. Сетевые настройки IRZ Bus

Рекомендуемые параметры устройства IRZ:

```bash
WIALON_HOST=158.160.19.253
WIALON_PORT=20332
WIALON_IMEI=865546046250136
WIALON_PASSWORD=<device_password>
```

Рекомендуемые параметры receiver:

```bash
LISTEN_HOST=0.0.0.0
LISTEN_PORT=20332
ALLOW_IMEI=865546046250136
ALLOW_PASSWORD=<device_password>

DB_HOST=158.160.19.253
DB_PORT=5432
DB_NAME=wialon_wifi
DB_USER=wialon_wifi
DB_PASSWORD=<db_password>
DB_SSLMODE=require
```

---

## 12. UFW hardening

Используйте скрипт:

```bash
sudo WIALON_ALLOW_CIDRS='192.168.1.230/32' \
     PG_ALLOW_CIDRS='203.0.113.10/32' \
     ./ops/ufw_hardening.sh
```

Скрипт добавляет адресные правила для `20332` и `5432`.
После применения обязательно удалить старые broad-правила типа `allow 20332/tcp` и `allow 5432/tcp`.

---

## 13. Идемпотентность и безопасность

Проект защищает от дублей на двух уровнях:
- unique по `raw_frame_id`
- semantic unique по ключевым полям observations/events

Базовые security принципы:
- не хранить секреты в git
- маскировать пароль login кадра в приложении
- ограничивать ingress по IP
- не давать приложению superuser-права

---

## 14. Проверка готовности к запуску

- [ ] Применены `sql/001..005` без ошибок
- [ ] `sql/006_smoke_test.sql` проходит
- [ ] Trigger `trg_parse_sd_from_raw_ai` существует
- [ ] `run_retention()` возвращает корректный результат
- [ ] Ежедневный cron установлен
- [ ] Receiver принимает TCP на `20332`
- [ ] UFW правила ограничены доверенными IP
- [ ] Секреты вынесены в env/secret manager

---

## 15. Исторические файлы в корне

Файлы `001_init_raw.sql ... 007_finalize_fix.sql` в корне репозитория сохранены для прозрачности истории доработок legacy окружения.

Для новых развертываний используйте именно:
- `sql/`
- `scripts/bootstrap_from_zero.sh`
- `scripts/install_retention_cron.sh`
- `ops/ufw_hardening.sh`

Это и есть основной путь **от 0 до полного создания и запуска**.
