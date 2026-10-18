-- @connection local
-- @database blog

-- ================================================
-- Blog: basic queries
-- ================================================
SELECT * FROM authors LIMIT 5;
SELECT * FROM posts ORDER BY created_at DESC LIMIT 10;
SELECT * FROM comments WHERE approved = TRUE ORDER BY created_at DESC LIMIT 10;

-- JOIN aggregations
SELECT p.title, a.username AS author, c.name AS category, p.status, p.published_at
FROM posts p
JOIN authors a ON a.id = p.author_id
JOIN categories c ON c.id = p.category_id
ORDER BY p.created_at DESC LIMIT 20;

SELECT p.title, GROUP_CONCAT(t.name SEPARATOR ', ') AS tags
FROM posts p
JOIN post_tags pt ON pt.post_id = p.id
JOIN tags t ON t.id = pt.tag_id
GROUP BY p.id, p.title ORDER BY p.id LIMIT 20;

SELECT p.title, COUNT(c.id) AS total_comments, SUM(c.approved) AS approved
FROM posts p LEFT JOIN comments c ON c.post_id = p.id
GROUP BY p.id, p.title HAVING total_comments > 0 ORDER BY total_comments DESC LIMIT 10;

-- Subqueries
SELECT * FROM posts WHERE author_id IN (SELECT id FROM authors WHERE id > 10) LIMIT 10;
SELECT title, (SELECT COUNT(*) FROM comments WHERE post_id = posts.id) AS comment_count
FROM posts ORDER BY comment_count DESC LIMIT 10;

-- UNION
SELECT 'active' AS status, COUNT(*) FROM authors WHERE id <= 3
UNION ALL
SELECT 'generated', COUNT(*) FROM authors WHERE id > 3;

-- Window functions (MySQL 8.0+)
SELECT title, author_id, created_at,
  ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY created_at) AS rn,
  RANK() OVER (PARTITION BY author_id ORDER BY created_at) AS rk
FROM posts LIMIT 20;

-- ENUM
SELECT DISTINCT status FROM posts;
SELECT status, COUNT(*) FROM posts GROUP BY status;

-- String functions
SELECT CONCAT('Hello, ', username) AS greeting, LENGTH(bio) AS bio_len FROM authors LIMIT 5;
SELECT UPPER(title), LOWER(slug) FROM posts LIMIT 5;
SELECT SUBSTRING(email, 1, 5) AS email_prefix FROM authors LIMIT 5;

-- Date functions
SELECT title, published_at, DATE_FORMAT(published_at, '%Y-%m-%d') AS fmt_date
FROM posts WHERE published_at IS NOT NULL LIMIT 10;

SELECT DATEDIFF(NOW(), published_at) AS days_ago FROM posts WHERE published_at IS NOT NULL LIMIT 10;
SELECT DATE_ADD(NOW(), INTERVAL 7 DAY) AS next_week, NOW(), CURDATE(), CURTIME();

-- Conditional functions
SELECT title, status,
  CASE status
    WHEN 'published' THEN 'published'
    WHEN 'draft' THEN 'draft'
    ELSE 'other'
  END AS status_label
FROM posts LIMIT 10;

-- Metadataj
SHOW TABLES;
DESC posts;
SHOW CREATE TABLE posts;
SHOW TABLE STATUS LIKE 'posts';

-- System functions
SELECT VERSION(), DATABASE(), USER(), CONNECTION_ID();
SELECT CHARSET('hello'), COLLATION('hello');

-- WITH RECURSIVE
INSERT INTO authors (username, email, bio)
WITH RECURSIVE seq (i) AS (
  SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 3
)
SELECT CONCAT('demo_', i), CONCAT('demo_', i, '@test.com'), 'demo bio' FROM seq;
DELETE FROM authors WHERE username LIKE 'demo_%';

-- Wide table (web_vitals: 54 cols)
SELECT * FROM web_vitals LIMIT 5;
SELECT url, COUNT(*), AVG(metric_01) AS avg_load, MAX(metric_05) AS max_ttfb
FROM web_vitals WHERE url != '/' GROUP BY url ORDER BY avg_load DESC LIMIT 10;

-- Performance analysis
SELECT url,
  ROUND(AVG(metric_01), 2) AS avg_load_time,
  ROUND(AVG(metric_05), 2) AS avg_ttfb,
  ROUND(AVG(metric_14), 4) AS avg_cls,
  ROUND(AVG(metric_08), 2) AS avg_lcp,
  ROUND(AVG(metric_13), 2) AS avg_fid
FROM web_vitals GROUP BY url ORDER BY avg_load_time DESC;

-- ============================================================
-- MySQL generic syntax (no table dependency)
-- ============================================================
SELECT JSON_OBJECT('key', 'value') AS obj;
SELECT JSON_ARRAY(1, 2, 3) AS arr;
SELECT JSON_EXTRACT('{"a":1,"b":2}', '$.a') AS val;
SELECT GROUP_CONCAT('a', 'b', 'c' SEPARATOR '-') AS concat_test;
SELECT ELT(1 + FLOOR(RAND() * 3), 'low', 'medium', 'high') AS priority;
SELECT FIELD('b', 'a', 'b', 'c') AS pos;
SELECT RAND(), ROUND(3.14159, 2), FLOOR(4.7), CEILING(4.3), ABS(-5), POWER(2, 3);
SELECT COALESCE(NULL, 'default') AS val, IFNULL(NULL, 'fallback') AS fb;
SELECT IF(1 > 0, 'true', 'false') AS bool_test;

-- JSON column (posts.metadata)
SELECT id, title, metadata FROM posts WHERE metadata IS NOT NULL LIMIT 10;

-- JSON path extraction (-> / ->>)
SELECT id, title,
  metadata->'$.reading_time' AS reading_time,
  JSON_UNQUOTE(metadata->'$.tags[0]') AS first_tag
FROM posts WHERE metadata IS NOT NULL ORDER BY id LIMIT 10;

-- JSON existence / containment
SELECT id, title FROM posts
WHERE metadata IS NOT NULL AND JSON_CONTAINS(metadata->'$.tags', '"rust"')
LIMIT 10;

SELECT id, title, JSON_EXTRACT(metadata, '$.views') AS views
FROM posts WHERE metadata IS NOT NULL ORDER BY JSON_EXTRACT(metadata, '$.views') DESC
LIMIT 10;

-- JSON aggregation over elements
SELECT JSON_ARRAYAGG(title) AS titles FROM posts WHERE metadata IS NOT NULL;

-- JSON key membership check (reading_time is a numeric member)
SELECT id, title, JSON_CONTAINS_PATH(metadata, 'one', '$.views', '$.tags') AS has_views_or_tags
FROM posts WHERE metadata IS NOT NULL LIMIT 10;

-- Full-text search (requires FULLTEXT index)
-- SELECT * FROM posts WHERE MATCH(title, body) AGAINST('Rust' IN BOOLEAN MODE) LIMIT 10;

-- @connection prod
-- @database inventory

-- ============================================================
-- Inventory: stock queries
-- ============================================================
SELECT * FROM warehouses;
SELECT * FROM suppliers ORDER BY rating DESC;

SELECT w.name, w.city, COUNT(s.item_id) AS item_types, SUM(s.quantity) AS total_units
FROM warehouses w LEFT JOIN stock s ON s.warehouse_id = w.id
GROUP BY w.id, w.name, w.city ORDER BY total_units DESC;

SELECT i.sku, i.name, s.quantity, w.name AS warehouse
FROM stock s
JOIN items i ON i.id = s.item_id
JOIN warehouses w ON w.id = s.warehouse_id
WHERE s.quantity < 100 ORDER BY s.quantity ASC;

-- Shipment tracking
SELECT sh.id, wf.name AS `from`, wt.name AS `to`, sh.status,
       GROUP_CONCAT(CONCAT(i.name, ' x', si.quantity) SEPARATOR ', ') AS items
FROM shipments sh
JOIN warehouses wf ON wf.id = sh.from_warehouse
JOIN warehouses wt ON wt.id = sh.to_warehouse
LEFT JOIN shipment_items si ON si.shipment_id = sh.id
LEFT JOIN items i ON i.id = si.item_id
WHERE sh.status != 'delivered'
GROUP BY sh.id, wf.name, wt.name, sh.status;

-- @database blog
SELECT
    a.username,
    DATE_FORMAT(p.created_at, '%Y-%m') AS month,
    COUNT(p.id) AS post_count
FROM
    authors a
JOIN
    posts p ON a.id = p.author_id
GROUP BY
    a.username,
    month
ORDER BY
    a.username,
    month;

-- @connection prod
-- @database cinema

-- ============================================================
-- Cinema: multilingual works, deep tree pagination
-- ============================================================
SELECT w.id, w.title, w.title_zh, w.kind, w.release_year, w.maturity, w.score
FROM works w
WHERE w.kind = 'anime'
ORDER BY w.score DESC LIMIT 10;

-- titles in multiple languages (en/zh/ja/ru/la)
SELECT w.title AS base, GROUP_CONCAT(CONCAT(t.lang, ':', t.title) SEPARATOR ' | ') AS titles
FROM works w JOIN work_titles t ON t.work_id = w.id
WHERE w.id IN (1, 2, 3, 10)
GROUP BY w.id, w.title;

-- deepest hierarchy: seasons -> episodes -> episode_lines (tree pagination demo)
SELECT s.work_id, s.season_no, e.ep_no, COUNT(el.id) AS line_count
FROM seasons s
JOIN episodes e ON e.season_id = s.id
LEFT JOIN episode_lines el ON el.episode_id = e.id
GROUP BY s.work_id, s.season_no, e.ep_no
ORDER BY s.work_id, s.season_no, e.ep_no
LIMIT 10;

-- voices across languages
SELECT c.name, c.name_zh, cv.lang, p.name_en AS voice
FROM characters c
JOIN character_voices cv ON cv.character_id = c.id
JOIN people p ON p.id = cv.people_id
WHERE cv.lang != 'ja'
ORDER BY c.id LIMIT 10;

-- ratings/reviews aggregation
SELECT w.title, wr.score, wr.votes, COUNT(r.id) AS review_count
FROM works w
JOIN work_ratings wr ON wr.work_id = w.id AND wr.source_id = 1
LEFT JOIN reviews r ON r.work_id = w.id
GROUP BY w.id, w.title, wr.score, wr.votes
ORDER BY wr.score DESC LIMIT 10;

-- multilingual reviews
SELECT w.title, r.title, r.lang, LEFT(r.body, 40) AS body_prefix, r.likes
FROM reviews r JOIN works w ON w.id = r.work_id
WHERE r.lang IN ('en', 'ja', 'ru', 'la')
ORDER BY r.likes DESC LIMIT 10;

-- JSON metadata spot checks
SELECT w.title, JSON_UNQUOTE(JSON_EXTRACT(w.metadata, '$.tags[0]')) AS first_tag
FROM works w WHERE w.metadata IS NOT NULL LIMIT 10;

-- type demo: BIT / TIME / BINARY / YEAR
SELECT e.id, e.ep_no, e.air_time, BIN(e.is_omake) AS omake, e.viewership
FROM episodes e WHERE e.is_omake = b'1' LIMIT 5;

SELECT t.id, t.title, t.duration FROM tracks t LIMIT 5;

-- @connection uat
-- @database history

SELECT * FROM civilizations;

SELECT * FROM regions;
-- ============================================================
-- History: POINT / ENUM / SET / JSON / BINARY / big timeline
-- ============================================================
-- capitals with POINT coordinates (via ST_AsText)
SELECT c.name_en, c.name_zh, ST_AsText(c.coord) AS coord, c.first_year, c.last_year
FROM capitals c ORDER BY c.first_year LIMIT 10;

-- famous battles with geometry + double armies
SELECT b.name_en, b.battle_date, ST_AsText(b.coord) AS coord,
       b.troops_a, b.troops_b, b.outcome
FROM battles b ORDER BY b.battle_date LIMIT 10;

-- SET column membership (find wars Rome/Mongol fought in)
SELECT w.name_en, w.started, w.ended, w.belligerents
FROM wars w
WHERE FIND_IN_SET('Rome', w.belligerents) OR FIND_IN_SET('Mongol', w.belligerents)
ORDER BY w.started LIMIT 10;

-- JSON honors on historical figures
SELECT f.name_en, f.name_zh, JSON_UNQUOTE(JSON_EXTRACT(f.honors, '$.temple')) AS temple
FROM historical_figures f WHERE f.honors IS NOT NULL LIMIT 10;

-- BINARY(16) archive id (hex)
SELECT l.title_en, HEX(l.source_hid) AS asset_hid FROM literary_works l LIMIT 5;

-- timeline big table pagination demo (2000 rows)
SELECT t.event_year, t.title_en, r.name_en AS region
FROM timeline_events t JOIN regions r ON r.id = t.region_id
ORDER BY t.event_year LIMIT 10;
SELECT t.kind, COUNT(*) FROM timeline_events t GROUP BY t.kind ORDER BY 2 DESC;

-- multilingual citations (918 rows, langs en/zh/ja/la/ru/fr/de)
SELECT c.quote_zh, c.lang, c.page_no, l.title_en AS source
FROM citations c LEFT JOIN literary_works l ON l.id = c.source_work_id
WHERE c.lang IN ('la', 'ru') LIMIT 10;

-- expedition POINT + SMALLINT scale demo
SELECT e.name_en, ST_AsText(e.departure) AS departure, e.ships_count, e.crew_count
FROM expeditions e ORDER BY e.start_year;

