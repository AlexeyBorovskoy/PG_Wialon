# PG_Wialon

Полный SQL-first проект для приема, нормализации и хранения Wialon IPS сообщений в PostgreSQL
(с акцентом на сценарий IRZ Bus и эксплуатацию в production).

---

## 1. Назначение проекта

`PG_Wialon` — это репозиторий с миграциями, эксплуатационными SQL-функциями и runbook-практиками для двух реальных задач:

1. **Новый (greenfield) запуск** Wialon-ориентированной схемы хранения:
   - raw слой кадров,
   - parsed слой `#SD#`,
   - слой Wi-Fi событий,
   - ретенция и безопасные права.

2. **Доработка уже существующей БД IRZ Bus (legacy/compatibility профиль)**,
   где уже есть таблицы `ips_frames / observations / events`, но требуется:
   - надежный парсинг `#SD#` из raw,
   - идемпотентность,
   - доиндексация,
   - ежедневная ретенция.

Проект ориентирован на PostgreSQL 13+ (проверено на PostgreSQL 16), не содержит облако-специфики SQL и применим как в managed, так и в self-hosted окружениях.

---

## 2. Что внутри репозитория

```
PG_wialon/
├── 001_init_raw.sql
├── 002_parsed_sd.sql
├── 003_wifi_events.sql
├── 004_retention.sql
├── 005_grants.sql
├── 006_finalize_wialon_db.sql
├── 007_finalize_fix.sql
└── wialon-retention.cron
```

### 2.1 Назначение файлов

- `001_init_raw.sql`
  - Создает схему `wialon`
  - Создает raw-таблицу `wialon.ips_frames`
  - Добавляет базовые индексы по времени, IMEI, типу кадра

- `002_parsed_sd.sql`
  - Создает parsed-таблицу `wialon.sd_parsed` для кадров `#SD#`
  - Связывает parsed слой с raw через `raw_frame_id`
  - Добавляет проверки диапазонов и индексы

- `003_wifi_events.sql`
  - Создает таблицу `wialon.wifi_events`
  - Добавляет дедуп-ключи и индексы `imei+time`, `bssid+time`

- `004_retention.sql`
  - Создает таблицу политик `wialon.retention_policy`
  - Добавляет функцию `wialon.run_retention()`

- `005_grants.sql`
  - Создает роль `wialon_app` (NOLOGIN)
  - Назначает безопасные права на схему, таблицы, sequence

- `006_finalize_wialon_db.sql`
  - **Compatibility миграция для уже существующей схемы IRZ Bus** (`ips_frames/observations/events`)
  - Добавляет индексы, дедуп, retention policy
  - Добавляет trigger-парсер `#SD#` из raw в `observations/events`

- `007_finalize_fix.sql`
  - Исправляет функции/триггер после production smoke-test
  - Добавляет backfill старых raw `#SD#` в нормализованные таблицы
  - Уточняет стабильность `run_retention()`

- `wialon-retention.cron`
  - Ежедневный скрипт запуска `SELECT * FROM wialon.run_retention(now());`

---

## 3. Протокол Wialon IPS (входной контракт)

### 3.1 Login frame

```
#L#IMEI,PASSWORD
```

### 3.2 Data frame (SD)

```
#SD#TIMESTAMP,LAT,LON,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-55;wifi_chan:6;wifi_event:appeared
```

### 3.3 Прочие кадры

В потоке могут встречаться:
- `#B#`
- `#P#`
- произвольные строки/шум сканеров

Все это должно попадать в raw слой `ips_frames` без потери.

---

## 4. Профили применения миграций

## 4.1 Профиль A: New Schema (greenfield)

Используется для **новой БД**, где нужна чистая модель:
- `wialon.ips_frames`
- `wialon.sd_parsed`
- `wialon.wifi_events`

Применение:

```bash
psql -v ON_ERROR_STOP=1 -d <db_name> -f 001_init_raw.sql
psql -v ON_ERROR_STOP=1 -d <db_name> -f 002_parsed_sd.sql
psql -v ON_ERROR_STOP=1 -d <db_name> -f 003_wifi_events.sql
psql -v ON_ERROR_STOP=1 -d <db_name> -f 004_retention.sql
psql -v ON_ERROR_STOP=1 -d <db_name> -f 005_grants.sql
```

## 4.2 Профиль B: Existing IRZ Bus DB (compatibility)

Используется, если в БД уже есть таблицы:
- `wialon.ips_frames`
- `wialon.observations`
- `wialon.events`
- `wialon.allowlist`

Применение:

```bash
psql -v ON_ERROR_STOP=1 -d wialon_wifi -f 006_finalize_wialon_db.sql
psql -v ON_ERROR_STOP=1 -d wialon_wifi -f 007_finalize_fix.sql
```

Важно:
- Профили A и B — **альтернативные**, не «сквозная цепочка 001..007».
- Для уже работающей IRZ Bus БД применяйте именно профиль B.

---

## 5. Архитектура данных

## 5.1 Raw слой

Таблица `wialon.ips_frames` хранит каждую строку, принятую по TCP:
- `received_at` — серверное время приема
- `remote_addr` — источник (ip:port)
- `imei` — идентификатор устройства (если известен)
- `frame_type` — `login / sd / b / p / login_raw / frame`
- `frame` — исходная строка

Это единый источник правды для forensic/повторного парсинга.

## 5.2 Parsed слой

В greenfield профиле: `wialon.sd_parsed`.

В compatibility профиле: `wialon.observations`.

Parsed слой выделяет:
- время кадра (`frame_ts`)
- BSSID
- RSSI
- канал
- доп. JSON (`extra`) с `lat/lon/wifi_event`

## 5.3 Слой событий

В greenfield профиле: `wialon.wifi_events`.

В compatibility профиле: `wialon.events`.

События фиксируют жизненный цикл наблюдаемого источника:
- `appeared`
- `disappeared`

События `seen` обычно остаются в observation-слое и аналитике, но при необходимости расширяются дополнительной миграцией.

---

## 6. Идемпотентность и дедупликация

Проект использует несколько уровней защиты от дублей:

1. Дедуп по raw reference:
   - unique `raw_frame_id` в observations/sd_parsed

2. Семантический дедуп:
   - уникальные индексы по ключевым полям (`imei, bssid, frame_ts, rssi, chan, type`)

3. Event-дедуп:
   - уникальный ключ `(imei, bssid, event_type, event_ts, source)`
   - уникальный ключ на `raw_last_id` + `event_type`

4. `ON CONFLICT DO NOTHING` в insert-path (trigger/fill pipeline)

Это позволяет безопасно повторять парсинг и backfill без размножения строк.

---

## 7. Ретенция

## 7.1 Политики хранения

Для compatibility профиля:
- `ips_frames`: 30 дней
- `observations`: 90 дней
- `events`: 180 дней

Для greenfield профиля:
- `ips_frames`: 30 дней
- `sd_parsed`: 30 дней
- `wifi_events`: 180 дней

## 7.2 Функция очистки

```sql
SELECT * FROM wialon.run_retention(now());
```

Возвращает удаленные строки по таблицам.

## 7.3 Cron

Скрипт `wialon-retention.cron` устанавливается, например, так:

```bash
sudo install -o root -g root -m 0755 wialon-retention.cron /etc/cron.daily/wialon-retention
sudo /etc/cron.daily/wialon-retention
```

---

## 8. Сетевые настройки (IRZ Bus)

Ниже — практический baseline для production.

## 8.1 Параметры IRZ (`secrets.conf` / UCI)

```bash
WIALON_HOST=158.160.19.253
WIALON_PORT=20332
WIALON_IMEI=865546046250136
WIALON_PASSWORD=<device_password>
```

## 8.2 Параметры receiver (`/etc/wialon-ips-receiver.env`)

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

## 8.3 Firewall hardening (обязательно)

Минимум:
- оставить `22/tcp` для админ-доступа
- ограничить `20332/tcp` только IP/подсетью IRZ устройств
- ограничить `5432/tcp` только доверенными админ/приложенческими IP

Пример UFW (шаблон):

```bash
# SSH
sudo ufw allow 22/tcp

# Wialon ingress только с подсети IRZ
sudo ufw delete allow 20332/tcp || true
sudo ufw allow from <IRZ_SUBNET_OR_IP> to any port 20332 proto tcp

# PostgreSQL только с доверенных адресов
sudo ufw delete allow 5432/tcp || true
sudo ufw allow from <ADMIN_IP_OR_SUBNET> to any port 5432 proto tcp

sudo ufw status numbered
```

---

## 9. Развертывание с нуля (quick start)

## 9.1 Подготовка БД/роли

```sql
CREATE ROLE wialon_wifi LOGIN PASSWORD '<strong_password>';
CREATE DATABASE wialon_wifi OWNER wialon_wifi;
```

## 9.2 Применение SQL

Выберите профиль:
- новый проект: `001..005`
- существующий IRZ Bus: `006..007`

## 9.3 Проверка объектов

```sql
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname='wialon'
ORDER BY tablename;

SELECT indexname
FROM pg_indexes
WHERE schemaname='wialon'
ORDER BY tablename, indexname;
```

---

## 10. Smoke-test (обязательно после деплоя)

## 10.1 Тестовые вставки

```sql
-- login
INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (now(), '127.0.0.1:9999', '865546046250136', 'login', '#L#865546046250136,***');

-- sd appeared
INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (
  now(),
  '127.0.0.1:9999',
  '865546046250136',
  'sd',
  '#SD#1700000000,59.9000,30.3000,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-55;wifi_chan:6;wifi_event:appeared'
);

-- sd disappeared
INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (
  now(),
  '127.0.0.1:9999',
  '865546046250136',
  'sd',
  '#SD#1700000060,59.9000,30.3000,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-70;wifi_chan:6;wifi_event:disappeared'
);
```

## 10.2 Проверочные SELECT

```sql
-- последние raw кадры
SELECT id, received_at, imei, frame_type, frame
FROM wialon.ips_frames
ORDER BY id DESC
LIMIT 20;

-- последние observations по imei (compatibility профиль)
SELECT id, raw_frame_id, imei, bssid, frame_ts, rssi_dbm, chan, extra
FROM wialon.observations
WHERE imei = '865546046250136'
ORDER BY frame_ts DESC, id DESC
LIMIT 20;

-- события по bssid за период
SELECT id, event_ts, imei, bssid, event_type, source, raw_last_id
FROM wialon.events
WHERE bssid = 'AA:BB:CC:DD:EE:FF'
  AND event_ts >= now() - interval '7 days'
ORDER BY event_ts DESC, id DESC;

-- последний статус по bssid
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

## 11. Эксплуатационные запросы

## 11.1 Объем данных

```sql
SELECT
  schemaname || '.' || tablename AS table_name,
  pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
  pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename)) AS index_size
FROM pg_tables
WHERE schemaname='wialon'
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
```

## 11.2 Кардинальности

```sql
SELECT 'ips_frames' AS table_name, count(*) AS rows FROM wialon.ips_frames
UNION ALL
SELECT 'observations', count(*) FROM wialon.observations
UNION ALL
SELECT 'events', count(*) FROM wialon.events;
```

## 11.3 Качество потока

```sql
-- доля полезного/шумового входа
SELECT
  count(*) FILTER (WHERE frame_type = 'sd')        AS sd_frames,
  count(*) FILTER (WHERE frame_type = 'login')     AS login_frames,
  count(*) FILTER (WHERE frame_type = 'login_raw') AS noise_or_non_wialon,
  count(*)                                         AS total
FROM wialon.ips_frames;
```

---

## 12. Риски и ограничения

1. Дедуп на текстовых payload
   - Мелкие отличия формата (регистр/пробелы) могут изменить семантический ключ.

2. Таймзоны и timestamp формат
   - `TIMESTAMP` в `#SD#` может приходить epoch/ISO/локальное время.
   - В проекте принята стратегия хранения в `TIMESTAMPTZ` и UTC-ориентация.

3. Частичные/битые кадры
   - Парсинг не должен ломать ingestion raw.
   - Ошибочный `#SD#` остается в raw и может быть переобработан после фикса парсера.

4. Шумовой трафик на 20332
   - При открытом порту в интернет появляются не-Wialon payload.
   - Обязательны allowlist/firewall ограничения.

---

## 13. Troubleshooting

## 13.1 `observations/events` пустые при наличии `sd`

Проверьте:

```sql
SELECT tgname
FROM pg_trigger
WHERE tgrelid='wialon.ips_frames'::regclass
  AND NOT tgisinternal;
```

Если триггера нет — примените профиль `006..007`.

## 13.2 Ошибка доступа к схеме

```sql
GRANT USAGE ON SCHEMA wialon TO wialon_wifi;
```

## 13.3 Ошибка sequence privileges

```sql
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA wialon TO wialon_wifi;
```

## 13.4 Ретенция не выполняется

Проверьте:

```bash
ls -l /etc/cron.daily/wialon-retention
sudo /etc/cron.daily/wialon-retention
```

---

## 14. Минимальный runbook релиза

1. Снять backup схемы/данных.
2. Применить миграции выбранного профиля.
3. Выполнить smoke-test (login + 2 SD).
4. Проверить триггер и индексы.
5. Проверить `run_retention()`.
6. Проверить receiver service status.
7. Проверить firewall и доступность 20332 только с доверенных источников.
8. Зафиксировать результаты в change-log.

---

## 15. Рекомендации по дальнейшему развитию

1. Добавить таблицу ошибок парсинга (DLQ) с reason-кодами.
2. Добавить материализованное представление «последний статус bssid».
3. Ввести partitioning по времени для `ips_frames` при росте нагрузки.
4. Добавить ingestion-metrics (rate, reject, parse-error, event-lag).
5. Унифицировать naming между профилями (`sd_parsed`/`observations`, `wifi_events`/`events`) через view-слой.

---

## 16. Версионирование и совместимость

- SQL в репозитории idempotent и рассчитан на повторный запуск.
- Любые изменения структуры должны идти через новые migration-файлы, без переписывания истории.
- Для production изменений всегда используйте dry-run на staging/clone перед боем.

---

## 17. Контрольный checklist перед production

- [ ] Выбран корректный профиль миграций (A или B)
- [ ] Применены миграции без ошибок
- [ ] Проверен trigger на `ips_frames`
- [ ] Проверены дедуп индексы
- [ ] Проверены права роли приложения
- [ ] Smoke-test кадров проходит
- [ ] `run_retention()` выполняется
- [ ] Cron ретенции установлен
- [ ] 20332 ограничен firewall по источникам
- [ ] 5432 ограничен firewall по источникам
- [ ] Секреты не попали в git

---

Если нужен отдельный `OPERATIONS.md`, `SECURITY.md` и `DEPLOY.md` с разбивкой по ролям (DBA/DevOps/Backend), добавляйте их как следующий шаг без изменения текущего SQL-ядра.
