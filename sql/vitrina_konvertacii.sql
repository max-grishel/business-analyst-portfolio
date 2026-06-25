-- ============================================================
-- Витрина операций конвертации валюты + аналитические запросы
-- Демонстрационный артефакт для портфолио бизнес-аналитика.
-- Диалект: PostgreSQL. Данные вымышленные.
-- Связано с: продуктовая страница (раздел «Метрики»), BPMN-схема.
-- ============================================================

-- ----------- СХЕМА ВИТРИНЫ -----------

CREATE TABLE dim_currency_pair (
    pair_id   INTEGER PRIMARY KEY,
    base_ccy  CHAR(3) NOT NULL,   -- валюта-источник
    quote_ccy CHAR(3) NOT NULL    -- валюта-назначения
);

CREATE TABLE fact_conversion (
    operation_id  BIGINT PRIMARY KEY,
    client_id     BIGINT NOT NULL,
    pair_id       INTEGER NOT NULL REFERENCES dim_currency_pair(pair_id),
    channel       VARCHAR(10)  NOT NULL,           -- 'app' | 'branch'
    source_amount NUMERIC(18,2) NOT NULL,          -- сумма в валюте-источнике
    target_amount NUMERIC(18,2),                   -- сумма к зачислению (NULL при отказе)
    quote_rate    NUMERIC(18,6) NOT NULL,          -- курс для клиента (с учётом спреда)
    market_rate   NUMERIC(18,6) NOT NULL,          -- рыночный курс
    spread_income NUMERIC(18,2),                   -- доход банка от спреда, в руб. (NULL при отказе)
    status        VARCHAR(10)  NOT NULL,           -- 'completed' | 'rejected'
    reject_reason VARCHAR(20),                      -- 'limit'|'aml'|'funds'|'quote_expired'|'transfer_failed'|NULL
    created_at    TIMESTAMP    NOT NULL,           -- момент показа курса
    confirmed_at  TIMESTAMP,                       -- момент подтверждения
    completed_at  TIMESTAMP                        -- момент завершения операции
);

-- ----------- ТЕСТОВЫЕ ДАННЫЕ -----------

INSERT INTO dim_currency_pair (pair_id, base_ccy, quote_ccy) VALUES
 (1, 'RUB', 'USD'),
 (2, 'RUB', 'EUR'),
 (3, 'USD', 'EUR');

INSERT INTO fact_conversion VALUES
 (1001,1,1,'app',    100000, 1075.00, 93.100000, 93.050000,  520.00,'completed',NULL,            '2026-06-01 10:00:00','2026-06-01 10:00:25','2026-06-01 10:00:27'),
 (1002,2,1,'app',     50000,  536.00, 93.200000, 93.100000,  260.00,'completed',NULL,            '2026-06-01 11:00:00','2026-06-01 11:00:40','2026-06-01 11:00:42'),
 (1003,3,2,'app',    200000, 2020.00, 99.000000, 98.900000,  800.00,'completed',NULL,            '2026-06-02 09:00:00','2026-06-02 09:00:15','2026-06-02 09:00:17'),
 (1004,4,1,'branch', 300000, 3180.00, 94.300000, 93.500000, 1200.00,'completed',NULL,            '2026-06-02 12:00:00','2026-06-02 12:05:00','2026-06-02 12:06:00'),
 (1005,5,1,'app',     80000,    NULL, 93.150000, 93.050000,    NULL,'rejected', 'funds',          '2026-06-03 08:00:00',NULL,NULL),
 (1006,6,2,'app',   1500000,    NULL, 99.100000, 98.950000,    NULL,'rejected', 'limit',          '2026-06-03 14:00:00',NULL,NULL),
 (1007,7,1,'app',    900000,    NULL, 93.250000, 93.100000,    NULL,'rejected', 'aml',            '2026-06-04 16:00:00',NULL,NULL),
 (1008,8,1,'app',     40000,    NULL, 93.300000, 93.200000,    NULL,'rejected', 'quote_expired',  '2026-06-04 17:00:00',NULL,NULL),
 (1009,9,3,'app',      5000, 5450.00,  1.085000,  1.084000,   30.00,'completed',NULL,            '2026-06-05 10:30:00','2026-06-05 10:30:10','2026-06-05 10:30:12'),
 (1010,10,1,'app',    60000,    NULL, 93.050000, 92.950000,    NULL,'rejected', 'transfer_failed','2026-06-05 18:00:00','2026-06-05 18:00:20',NULL);

-- ============================================================
-- АНАЛИТИЧЕСКИЕ ЗАПРОСЫ
-- ============================================================

-- Q1. Объёмы и доход по спреду за период, в разрезе каналов.
-- Бизнес-вопрос: сколько операций и какой доход приносит каждый канал?
SELECT channel,
       COUNT(*)                                                       AS operations,
       SUM(source_amount)                                             AS total_source_amount,
       SUM(CASE WHEN status = 'completed' THEN spread_income ELSE 0 END) AS spread_income
FROM   fact_conversion
WHERE  created_at >= DATE '2026-06-01'
  AND  created_at <  DATE '2026-07-01'
GROUP  BY channel
ORDER  BY spread_income DESC;

-- Q2. Топ валютных пар по доходу со спреда (только завершённые).
-- Бизнес-вопрос: какие пары приносят банку больше всего?
SELECT p.base_ccy || '/' || p.quote_ccy AS pair,
       COUNT(*)                          AS completed_ops,
       SUM(f.spread_income)              AS spread_income
FROM   fact_conversion f
JOIN   dim_currency_pair p ON p.pair_id = f.pair_id
WHERE  f.status = 'completed'
GROUP  BY p.base_ccy, p.quote_ccy
ORDER  BY spread_income DESC;

-- Q3. Конверсия: доля завершённых операций от всех инициированных.
-- Бизнес-вопрос: какой процент начатых обменов доходит до конца?
SELECT COUNT(*)                                                          AS total_ops,
       SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END)             AS completed_ops,
       ROUND(100.0 * SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END)
                    / COUNT(*), 1)                                       AS completion_rate_pct
FROM   fact_conversion;

-- Q4. Структура отказов по причинам.
-- Бизнес-вопрос: почему операции отклоняются и что чинить в первую очередь?
SELECT reject_reason,
       COUNT(*)                                          AS rejects,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM   fact_conversion
WHERE  status = 'rejected'
GROUP  BY reject_reason
ORDER  BY rejects DESC;

-- Q5. Среднее время от показа курса до подтверждения (для завершённых), в секундах.
-- Бизнес-вопрос: быстро ли клиент принимает решение? (косвенно — про TTL котировки)
-- PostgreSQL:
SELECT ROUND(AVG(EXTRACT(EPOCH FROM (confirmed_at - created_at)))::numeric, 1)
           AS avg_seconds_to_confirm
FROM   fact_conversion
WHERE  status = 'completed'
  AND  confirmed_at IS NOT NULL;
-- Oracle-эквивалент разницы времени: AVG((confirmed_at - created_at) * 86400)

-- Q6. Доля операций, отклонённых из-за устаревшей котировки.
-- Бизнес-вопрос: часто ли клиенты не успевают в TTL? (вход для подбора TTL — см. US-2)
SELECT ROUND(100.0 * SUM(CASE WHEN reject_reason = 'quote_expired' THEN 1 ELSE 0 END)
                    / COUNT(*), 1) AS quote_expired_share_pct
FROM   fact_conversion;
