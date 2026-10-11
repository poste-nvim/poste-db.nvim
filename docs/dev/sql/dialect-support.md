# 新增 SQL dialect 支持 — 设计与触点清单

> 修订记录（相对初版）：
> 1. 优先级重排——按"收益高、贴现有 TCP 驱动架构的先做，引入新传输架构的集中一期，模型不匹配的延后"排序。
> 2. §二别名机制拍板：走 mariadb 先例（Lua 侧归一化），Rust 零改动；废弃"Rust 侧加 name 映射"方案。
> 3. 修正事实错误：官方 `clickhouse` crate 是 HTTP-only，不是"HTTP + native TCP"。
> 4. §3.2 测试计划按传输方式拆分，消除"HTTP 方言 `dialect_for` 返回 Some"与"HTTP 仍返回 None"的自相矛盾。
> 5. 补全 Lua 触点清单：`SYSTEM_SCHEMAS`、`ident.lua`/`dml.lua` 引用分支、`dialect_icons`、`ai/system_prompt.lua` 方言清单、双端 `to_url()` 同步。
> 6. 容器方案修正：MSSQL arm64/健康检查、Trino tpcds 需挂 properties 且 tpch 只读、ClickHouse 连接端口语义 pin 为 HTTP 8123。
> 7. 措辞修正：URL 是"构造"不是"解析"；验收标准的"建库/建表"改为"列库/列表"。
>
> **实施状态**：Phase 0（别名）、Phase 1（MSSQL）、Phase 2（HTTP 传输 + ClickHouse，含 Lua/Rust/容器/playground/diag）
> poste.nvim main 直接演进（原 `../poste-for-db` worktree 流程已废弃）。

## 背景

poste-db 目前支持的 dialect：`postgres`（含 `postgresql` 及 PG 系别名）、`mysql`（含 `mariadb` 及 MySQL 系别名）、`sqlite`、`mssql`。

实现成本分布（触点按现状逐一核对过，完整清单见文末附录）：

- **Lua 侧**（poste-db.nvim）：
  - `constants.lua`：`SUPPORTED_DIALECTS` 白名单 + `SYSTEM_SCHEMAS` + `DIALECT_ALIASES` 归一表 + `URL_SCHEMES`/`dialect_from_url` 嗅探 + `DIALECT_DEFAULT_PORTS`
  - `connections.lua`：URL 构造（消费 `default_port`，scheme 无关）+ `dialect_icons`
  - `ident.lua` / `dml.lua`：标识符引用与值转义的方言分支
  - `completion/data.lua`：`tables_db_flag` 的 schema/database 归类 + 方言关键字
  - `snippets.lua`：`pick_template` 模板变体
  - `source_format.lua`：格式化器 `dialect_map`
  - `ai/system_prompt.lua`：方言清单提示词
- **Rust 侧**（poste.nvim，直接在 main 改）：
  - `poste-core` 的 `Protocol` 枚举加变体
  - `sql_connection.rs` 的 `ConnectionConfig::to_url()`——**与 Lua 的 `resolve_connection_url` 是镜像实现，必须双端同步**
  - 驱动分发（`sql_executor/`、`exec_file.rs`、`session.rs`、`introspect.rs` 的 scheme/dialect 链）
  - `sql_dialect.rs` 的 `Dialect` trait 实现（introspection SQL、引号、端口、类型映射）
- `mariadb` 走 MySQL 线协议，Lua 侧归一化为 `mysql`（`DIALECT_ALIASES` 先例）。

架构要点：`Dialect` trait 只封装 SQL 方言差异（introspection SQL、引号、端口、类型映射），与传输方式无关。HTTP 是**传输属性**，不是 `dialect_for` 的排除理由——ClickHouse/Trino 这类"SQL over HTTP"的数据库可以有自己的 `Dialect` 实现，同时由传输层路由到 HTTP 执行器；`dialect_for` 对 Redis 等非 SQL 协议仍返回 `None`。

## 一、优先级

排序原则：**收益高、能贴现有 TCP 驱动架构的先做；引入新传输架构（HTTP）的集中到一期做，摊薄基建成本；数据/连接模型不匹配的最后，可延后。**

| 优先级 | Dialect | 驱动/传输 | 工作量 | 风险 | 说明 |
|-------|---------|----------|--------|------|------|
| 0 | PG/MySQL 兼容系别名 | 复用现有 TCP 驱动 | ≈0 | 无 | ✅ 已落地（§二） |
| 1 | MSSQL / SQL Server | `tiberius`（纯 Rust TCP） | 中 | 低-中 | ✅ 已落地。容器侧的坑（arm64 模拟、健康检查）见 §四 |
| 2 | ClickHouse | reqwest 直连 HTTP | 中 | 中 | ✅ 已落地。**实现注记**：官方 `clickhouse` crate 是 SELECT 取向（把 ` FORMAT x` 拼进 SQL、强制 `readonly=1`），无法跑 DDL/DML/临时表/`SET`——改用 reqwest 裸 HTTP（`default_format=JSON`，meta 带列类型），即 poste-exec 首个 HTTP 传输，Trino 直接复用 |
| 3 | Trino | 复用 reqwest HTTP 传输 | 中 | 中 | 数据湖联邦查询主流；只做 Trino，**Presto 不在范围**（协议已分叉，不做别名） |
| 4 | DuckDB | `duckdb` crate（链接 libduckdb 原生库） | 高 | 高 | 仅文件模式（见 §四）；链接 libduckdb 构建重，且与服务器连接模型不一致。可延后，延后不阻塞任何验收 |

## 二、零/近零成本 dialect（纯别名，机制已落地）

**机制：走 mariadb 先例，Lua 侧归一化。** `constants.lua` 的 `DIALECT_ALIASES`（alias → base 方言）+ `connections.lua` 在白名单检查前归一化。**Rust 零 diff**——别名在到达 Rust 之前已经变成 `postgres`/`mysql`。

设计后果（接受的 trade-off）：

- 图标、completion、AI prompt 一律按 base 方言呈现，别名不引入任何专属分支。每个别名的持续成本 = 一个 map 条目。
- 展示层的 provider 区分（如 supabase/neon 角标）**不做**，留待有真实需求再加 `provider` 字段。
- 归一化后 `resolve_connection_url` 自然构造出 `postgres://`/`mysql://`，杜绝"二元 scheme 兜底把别名静默构造成 `mysql://`"的误路由。

### PostgreSQL 兼容系（→ postgres）

cockroachdb、yugabyte、aurora-postgres、neon、supabase、timescaledb（实质是 pg 扩展）

### MySQL 兼容系（→ mysql）

tidb、singlestore、aurora-mysql、vitess、planetscale

## 三、自动化测试

新增 dialect 的测试分三层，全部纳入现有 `tests/run.sh` 体系。

### 3.1 Lua 单元测试（无 Docker，随 `tests/run.sh` 运行）

纯 stub 测试，跟随现有 `tests/sql/*_spec.lua` 惯例：

| 文件 | 要补的用例 |
|------|-----------|
| `sql_constants_spec.lua` | `SUPPORTED_DIALECTS`/`is_sql_dialect`；`DIALECT_ALIASES` 归一断言；`dialect_from_url` 各前缀；`default_port`；`SYSTEM_SCHEMAS` 新增条目 |
| `sql_connections_spec.lua` | **断言构造出的 URL**（代码路径是构造，不解析用户输入的 scheme）：新方言前缀、默认端口正确；别名断言落到 base 协议 URL（防二元兜底误路由） |
| `sql_ident_spec.lua` + dml | `ident.quote`/`quote_literal`、`dml.lua` 值转义的新方言分支 |
| `sql_completion_spec.lua` | 方言关键字/内置函数；`tables_db_flag` 归类 |
| `sql_snippets_spec.lua` | `pick_template` 命中新方言变体 |
| `sql_source_format_spec.lua` | 各格式器 `dialect_map` 补条目 |

**`tables_db_flag` 归类**（现状）：postgres/postgresql/sqlite/mssql → `--schema`；mysql/mariadb（及未知）→ `--database`。

**`SYSTEM_SCHEMAS`**（`semantic_diagnostics.lua` 在消费）：现含 pg 系 + mysql 系 + `sys` + `guest`；ClickHouse/Trino 落地时加 `system`。

### 3.2 Rust 单元测试（poste.nvim crate）

**按传输方式拆分：**

- **TCP 驱动方言（如 MSSQL）**：在 `crates/poste-exec/src/sql_dialect.rs` 写 `Dialect` impl + 测试模块，镜像现有 `test_postgres_dialect()` / `test_mysql_dialect()` / `test_sqlite_dialect()`，覆盖 trait 全部方法（含 `type_mapping`）；`dialect_for` 断言 Some；Redis 等非 SQL 协议仍 None；introspection SQL 快照断言
- **SQL over HTTP 方言（ClickHouse/Trino）**：同样在 `sql_dialect.rs` 实现 `Dialect` 并做快照测试；`dialect_for` 返回 Some（Dialect 与传输解耦）；传输分发单测断言路由到 HTTP 执行器

### 3.3 集成测试（需 Docker，gated）

- `tests/diag/diag_<dialect>.lua`（参照 `diag_sql.lua`/`diag_mssql.lua`）：环境变量 gate（如 `MSSQL_TEST_URL` + `POSTE_BINARY`），未设则 SKIP；连真实容器跑 introspection 全链路 + 特性 SQL
- Busted 单测必须保持无 Docker 可运行

### 3.4 兼容系别名

- 只做 Lua 侧测试：`connections.toml` 能写别名、归一化后 URL 落到 `postgres://`/`mysql://`；复用现有容器

## 四、Docker container

在 `playground/docker-compose.yml` 追加服务（宿主端口避开已用的 15432/13306/13307/11433/18080/18123/19000）：

| 服务 | 镜像 | 宿主端口 | 健康检查 |
|------|------|---------|---------|
| `mssql` ✅ | `mcr.microsoft.com/mssql/server:2022-latest`（**amd64-only**，声明 `platform: linux/amd64`） | `11433:1433` | `/opt/mssql-tools18/bin/sqlcmd ... -C -b`（**必须 `-C`** 信任自签证书） |
| `clickhouse` | `clickhouse/clickhouse-server:latest` | `18123:8123`（HTTP，**连接层只用这个**）/ `19000:9000`（native，备用） | `wget -qO- http://localhost:8123/ping` 返回 `Ok` |
| `trino` | `trinodb/trino:latest` | `18080:8080` | `curl -f http://localhost:8080/v1/info` 且 `starting=false` |
| `duckdb` | 官方 CLI 构建的文件模式（无服务进程） | 无需端口 | 文件模式无探活；HTTP 服务模式**明确不做** |

初始化方式差异与坑：

- **MSSQL**（已踩平，见 `playground/init/mssql/entrypoint.sh`）：无官方 arm64 构建，Apple Silicon 靠 Rosetta/QEMU，启动慢需 `start_period: 120s`；不读 `docker-entrypoint-initdb.d`，自定义 entrypoint 启动 `sqlservr` 后 sqlcmd 灌种子；种子用 GO 分批（sqlcmd 消费），`GENERATE_SERIES` 不能用 `AS s(n)` 列别名（列名固定 `value`），`datetime2` 不支持 `- 整数` 算术；**每次重启重播种子（数据重置），与其它服务不同**
- **ClickHouse**：原生支持 `/docker-entrypoint-initdb.d/*.sql`。连接语义 pin：`clickhouse://user:pass@host:18123/db` 走 HTTP 8123
- **Trino**：镜像默认只启用 `tpch`（+system）；**tpcds 需挂 `etc/catalog/tpcds.properties`**；`tpch` 只读，自建核心表进 `memory` catalog（只支持 CTAS、重启即失，需启动后置脚本重建）
- **DuckDB**：入口脚本用 duckdb CLI 生成种子 `.duckdb`（同 sqlite 的 `test.db` 模式）；URL `duckdb:<path>` 沿 `sqlite:` 前缀先例；Rust 驱动 `duckdb` crate（链接 libduckdb，构建重）

## 五、初始化数据

在 `playground/init/<dialect>/` 放种子脚本，遵守现有约定：单文件 <8KB、手工 3-7 行真实样例 + 批量生成、依赖库无关。

- 跨引擎核心表（`users`/`orders`/`order_items`）保证同一份查询全容器跑通；Trino 例外：核心表放 `memory` catalog 启动重建，`tpch`/`tpcds` 只读联邦查
- README 补各库表/行数清单（参照 mssql 小节格式）

## 六、Playground SQL 脚本

`playground/queries/<dialect>.sql`：头注释列特性 + `-- @connection`/`-- @database` 头。**段落分隔用 `--` 注释，不要用 `###` 行**（exec-file 只剥离独立的 `###` 行）。参照 `mssql.sql`。

## 验收标准（每步）

1. 新方言可写入 `connections.toml` 并正常连接
2. 连接后 introspection（列库/列表/列/索引）正常
3. completion 与 snippets 对新方言生效
4. `source_format.lua` 映射补齐，格式化不报错
5. 3.1/3.2 单元测试无 Docker 全绿；3.3 diag 全绿
6. docker-compose 新增服务健康检查通过，初始化数据就位
7. playground SQL 脚本完整跑通
8. 兼容系别名：Rust 零 diff
9. Lua 触点清单全覆盖（含 `ai/system_prompt.lua`）
10. 双端 `to_url()` 同步，无静默误路由

## 建议实施顺序

1. ~~别名铺开~~ ✅
2. ~~MSSQL~~ ✅
3. **HTTP 传输层 + ClickHouse**（下一步：poste-exec 首个 HTTP 传输在此消化）
4. Trino（复用 HTTP 传输）
5. DuckDB（可选，延后）

每步完成标准：3.1/3.2 测试先行并全绿 → docker 服务健康检查 → init 数据就位 → playground 跑通 → diag 全绿 → `ai/system_prompt.lua` 已更新。

---

## 附录：新增方言触点清单（动手前照单全查）

### Lua 侧（poste-db.nvim）

| # | 文件 | 要动什么 |
|---|------|---------|
| 1 | `constants.lua` | `SUPPORTED_DIALECTS`；别名进 `DIALECT_ALIASES`；系统 catalog 进 `SYSTEM_SCHEMAS`；`URL_SCHEMES` 加前缀；`DIALECT_DEFAULT_PORTS` 加端口 |
| 2 | `connections.lua` | URL 构造与显示走 `default_port()`（通常零改动）；`dialect_icons` 加图标 |
| 3 | `ident.lua` | `quote` 标识符引用分支；`quote_literal` 值转义 |
| 4 | `dml.lua` | 编辑流 DML 生成中的方言分支 |
| 5 | `completion/data.lua` | `tables_db_flag`（`--schema` vs `--database`）归类 |
| 6 | `snippets.lua` | `CATEGORIES` 加方言变体（`pick_template` 自动生效） |
| 7 | `source_format.lua` | sqlfluff / sql-formatter 的 `dialect_map` |
| 8 | `ai/system_prompt.lua` | 方言清单句 |
| 9 | specs | `sql_constants` / `sql_connections`（**URL 构造断言，防静默误路由**）/ `sql_ident` / `sql_snippets` / `sql_completion`（tables_db_flag） |

### Rust 侧（poste.nvim main 直接改）

| # | 位置 | 要动什么 |
|---|------|---------|
| 1 | `poste-core/src/request.rs` | `Protocol` 变体 |
| 2 | `poste-exec/src/sql_connection.rs` | `to_url()` dialect 分支 + `test_connection` 探活。**与 Lua `resolve_connection_url` 是镜像实现，双端必须同步** |
| 3 | `poste-cli/src/exec_file.rs` | scheme→protocol 链 + `run_statements` 分发 + `exec_<dialect>` + summary dialect 字符串 |
| 4 | `poste-cli/src/session.rs` | scheme 链 + `session_<dialect>`（会话语义随驱动而异：temp table/事务，参考 `sql_executor/mssql.rs` 的批量路径注记） |
| 5 | `poste-cli/src/introspect.rs` | dialect_name 链。**此链静默 fallback 到 postgres——新方言必须显式加分支** |
| 6 | `poste-exec/src/sql_dialect.rs` | `Dialect` impl + `dialect_for` 分支 + 快照测试（参考 `test_mssql_dialect`） |
| 7 | `poste-exec/src/sql_executor/{mod.rs,<dialect>.rs}` | 驱动模块 + 分发 match + `make_response` 协议名 |
| 8 | `poste-exec/src/sql_introspect/{mod.rs,<dialect>.rs}` | introspect 驱动 + 分发（item 形状对齐 `postgres.rs`） |
| 9 | `poste-exec/src/sql_ddl.rs` | `DdlGenerator` + `ddl_for` 分支 |
| 10 | `poste-cli/src/connection.rs` | CLI 连接列表 emoji（cosmetic） |

### mssql 实测踩过的坑（新驱动参考）

- **TDS 临时表作用域**：`CREATE TABLE #t` 必须走批量路径（`simple_query`），RPC prepare/execute 作用域退出即丢弃——见 `mssql_execute` 的 `is_ddl_stmt` 路由
- **MERGE 必须以分号结尾**，而语句切分会剥掉尾分号——执行层补回
- 事务无需专门 API：BEGIN/COMMIT/ROLLBACK 走批量路径，服务器以 ENVCHANGE 回报描述符
- 值转换参考 `mssql_value_to_json`（tiberius `try_get` 返回 `Option<T>`，借用型 `&str`/`&[u8]`，数值/日期走 `value.rs` 共享 fallback）
- HTTP 型方言：`clickhouse` crate 是 HTTP-only（RowBinary over HTTP）；`Dialect` 与传输解耦，参考"背景"一节
