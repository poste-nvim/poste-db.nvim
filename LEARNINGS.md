# LEARNINGS

> Agent 踩坑实录。每条都来自本仓库真实发生过的错误（2026-08 架构重构会话），
> 不是泛泛的最佳实践。动手前扫一遍，同类错误不要犯第二次。
>
> 配套 harness：`.opencode/skills/sql-audit-harness/`（证据规则）、
> `sql-refactor-harness`（留壳/Lua 陷阱）、`sql-architecture-harness`（原语入口）。

## 1. 审计 hearsay 不是证据

**发生了什么**：子代理审计报告的多个"死代码/坏味道"结论经复核是错的——

- `format.format_number` 被判死代码，实际有 `sql_format_bigint_spec` 覆盖；
- `state._hide_header_float` / `_hide_row_numbers` 被判"写了没人读的死状态"，
  实际是**用户可从外部设置的隐藏开关**（"只读未写"≠死）；
- `nav_cell.toggle_cell_highlight` 生产零调用但有测试，属"仅测试暴露面"，
  删除是产品决策不是清理；
- 光标双真相源（`tab.cursor` vs `sql_state.cell`）被判"结构性漂移"，
  逐点枚举读写点后发现双写仅 3 处且同步点全部正确——最终结论修订为"暂不做"。

**约束**：子代理产出 = 假设。任何要写进报告或据此动手的论断，必须自己
grep + 读码复核并在报告中标注 verified / inferred。结论被推翻时显式写修订
记录，不要静默改写。

## 2. 0 命中的 grep 先怀疑 grep 自己

**发生了什么**：shell 循环里 `grep -c "$m\."`，当 `$m` 是 `D\.` 时实际模式
变成 `D\.\.`，匹配 0 次 → 误判 `dataset` require 无用 → 删掉 →
`D.T()` 在运行时报 `attempt to index global 'D' (a nil value)`。全量测试抓住。

**约束**：以"0 命中"为由的删除，必须先打印模式、对照真实调用形态
（`D.T()` 要匹配 `D\.T`；`M.x` / local 别名 / 方法调用 / `_test` 导出都要各查一遍），
删除后跑 `tests/run.sh`。grep 是必要条件，不是充分条件。

## 3. `M.x` 降级 local：先查所有调用点的词法位置

**发生了什么**：`format.lua` 把 `M.normalize_type` 改成 local，但
`is_numeric_column`（约 180 行）在定义（约 438 行）之前调用 →
`attempt to call global 'normalize_type' (a nil value)`，套件 2 例失败。
这就是 AGENTS.md「Local function forward declaration」规则的变体——
坑不在定义与调用相邻时，而在两者相距几百行时。

**约束**：`M.x` → local 前，grep 全部调用点；任一调用在定义之前，
要么前置声明 `local x`，要么把定义整体上移到首个调用之前。

## 4. `and f() or f` 的 nil 陷阱

**发生了什么**：`db_browser/theme.lua` 第一版写
`type(spec) == "function" and spec() or spec`，operations 的 spec 函数按
设计返回 nil（"已定义则跳过"）→ `and spec()` 得 nil → 表达式回落到 `spec`
本身（函数）→ 函数被传给 `nvim_set_hl` → `Expected Lua table`，
整棵 require 链炸掉且报错位置在链的最外层，极难定位。

**约束**：中间结果可能为 nil/false 时禁止 `and-or` 取值惯用法，用显式 if。
依赖链上的 require 错误会报在最外层 require 处——看到"loop or previous
error loading module 'X'"时，真错误在 X 的加载过程里，不在引用它的地方。

## 5. 重构要清场：壳留在原地就是没做完

**发生了什么**：历次 refactor 留下一批空壳，本次全部清理——
`invalidate_sep_cache()` 空函数 + 4 处仪式性调用、`clear_panel(seq)` 被忽略
的参数、`context_client.lua` 173 行零引用模块、`HEADER_LINES = 0` 贯穿
29 处的无效减法。这些壳的存在说明"拆出 seam"和"删旧路径"被当成了两件事。

**约束**：抽取 seam 与删除旧壳在**同一批 commit** 内完成。挑一个 seam 时
先问：它的旧壳还在吗？

## 6. 合并重复实现 = 替别人选行为，要把增量说清

**发生了什么**（都是有意为之并已记录在 commit/报告里）：

- 两份 `format_bytes` 输出不同（`kB`/2 位小数 vs `KB`/1 位小数）→ 统一取一版；
- 四份补全抓取脚手架的退出语义不同 → 统一采用 ensure_columns 版，
  顺带修复另外三份「job 0 退出 + 空 stdout → 回调永久悬挂」的潜在缺陷；
- flash 的高亮组并入统一主题后，获得了它原本没有的用户 override 支持。

**约束**：去重不是纯搬移。逐项列出行为增量（输出格式、失败值、新能力），
写进 commit message；用户可见的输出变化（如 `kB`→`KB`）必须显式声明。

## 7. 模块间搬代码：先枚举闭包捕获，再动手

**发生了什么（做对了的样例）**：`sql_runner` 的 `on_response`/`on_error`
两个 ~200 行闭包拆到 `sql_runner/response.lua` 时，先把捕获的上游变量
全部列成显式 `deps` 表（`exec_seq` 这类活状态以 getter 传入），搬移才是
纯文本级、零行为风险的。

**约束**：跨模块搬移前，把闭包捕获的每个上游变量写下来，逐个变成 deps
字段或参数。捕获表本身就是该函数的依赖清单，拆完还可以顺手删掉供体模块
不再需要的 require。

## 8. `package.loaded` 桩的捕获时机

**发生了什么（做对了的样例）**：`sql_sql_runner_spec` 在 require
`poste-db.sql_runner` **之前**桩掉 `poste.state`、`poste.indicators` 等。
给 sql_runner 拆出的新模块如果顶层 require 这些依赖，会拿到同样的桩；
但如果顶层 require 的是**没被桩的模块**（如 `poste-db.context`），会真的加载。
后者当时被刻意保持为惰性 require。

**约束**：给被桩 spec 覆盖的模块加新的顶层 require 前，先看 spec 桩了什么、
桩是 require 前安装的吗？未桩的依赖一律惰性 require 到函数体内。

## 9. UX 可见的框架迁移不在 headless 会话里做

**发生了什么（做对了的样例）**：`forms.lua` 退役并入 `forms_advanced`
会把 operations 的三个对话框换成另一套表单框架——焦点、编辑流、取消语义
都没有测试覆盖，headless 跑不出来的东西就不能算验证过。已deferred 并在
报告中写明迁移路径。

**约束**：改用户可见 UX 的重构需要"真实会话验证"这一步。headless 套件
全绿 ≠ 可以迁。做不了真机验证就 defer 并文档化，不要硬迁。

## 10. 与用户未提交工作共存

**发生了什么**：会话开始时工作区有用户 WIP（sql_runner 指示器逻辑），
会话中途又出现了新的用户编辑（connections.toml、mysql-test.sql）。

**约束**：动手前 `git status`；用户 WIP 单独成 commit（如实描述其内容），
自己的重构分批 commit，绝不混在一个 diff 里。会话中随时可能冒出新的用户
编辑——收尾时如发现不认识的改动，不要动它。

## 11. tree-sitter 误报过滤器：同一构造有多种 recovery 形状

**发生了什么**：给 `ts_stmt.find_error_nodes` 补 mssql/clickhouse 误报过滤时，
`STRING_AGG(x, ', ') WITHIN GROUP (ORDER BY y)` 一个构造在树上留下
**三种** ERROR 形状，取决于上下文：① `GROUP (ORDER BY y) AS z`（head 被
invocation 吞掉，多列 select 时）；② `STRING_AGG(x, ', ') WITHIN`
（invocation + 孤立 WITHIN，末列时）；③ 残片 `o.status`（伪 `GROUP (...)`
invocation 内的限定列，已有 bare-word 过滤只匹配 `^[%w_]+$` 覆盖不到）。
第一版过滤器只覆盖 ①，套件跑出 ②③。另外 `syntax.lua` 的去红高亮是
`find_error_nodes` 的**手写镜像**（`KNOWN_CONSTRUCT_MARKERS` +
`CONSTRUCT_KEYWORDS`），新过滤器不同步它就会出现"诊断没了但还红着"；
本次 OFFSET/FETCH 着色缺失就是因为 `CONSTRUCT_KEYWORDS` 里没有这几个词。

**约束**：加误报过滤器前先用探针脚本（headless nvim 解析目标 SQL、dump 全部
ERROR 节点的 text/parent/祖先链）确认形状，同构造多形状各配一条规则；每个
过滤器配一对测试（误报被吞 + 真实错误 `SELECT * FORM users` 仍要报）。
同步改 `syntax.lua` 的两个表；改动含结构判定的（prev/next sibling）至少在
两个方向各验一次——临时 stash 修复跑新测试，确认真能抓到原 bug。

## 12. 种子脚本的时序 bug 在首次 init 时不可见

**发生了什么**：`playground/init/clickhouse/01-playground.sql` 先 INSERT 进
`events_raw`、后建 `TO events_daily` 型物化视图——TO 型 MV 只聚合**创建之后**
的插入，首次 init 没有任何报错，但 `events_daily` 永远是空的
（`countMerge(cnt)` 查询返回 0 行）。同一文件还有第二个时序坑：顶层 DROP
清单漏了 `events_raw`，首次 init 一切正常，重跑才炸 TABLE_ALREADY_EXISTS。

**约束**：新方言种子落盘后，立即对真实容器 `docker exec -i ... < seed.sql`
**完整重跑一遍**（不只验首次 init），再抽验每张表的行数 > 0；涉及 MV/CTAS/
触发器类"由数据驱动"的对象时，把建对象和灌数据的先后顺序当显式测试点。

## 13. gsub 字面查找必须 pesc；特征测试用全串 equals

**发生了什么**：给拆分出的 `copy_ddl.lua` 补特征测试，一次抓到三个潜伏
bug：① `rename_seq_reference`（copy_ddl.lua:93）把 `nextval('...')` 直接当
`gsub` 的 pattern——括号是魔法字符，**从未匹配过**，复制出的表 DEFAULT 仍指
向旧序列（同服务器靠旧序列存在侥幸可用，计数器却已错乱；跨服务器 DDL 直接
失败）；② `rename_routine_in_def` mysql 分支（copy_ddl.lua:159）`sub(1,
open)` 多含一个反引号又手拼一个，产出 `` ``proc_copy`` ``——MySQL 把双反引
号解析成转义的字面反引号，DDL 无效；③ `prepare_table_ddl` 对 schema 限定
的 nextval 引用再拼一次 schema 前缀，`CREATE SEQUENCE "public"."public".…`
与改写后的 DEFAULT 指向不一致。三者都在生产路径上存活了很久，因为拆分前
没有任何测试，且 ①③ 的损坏形态（"旧值仍在" / "多一层前缀"）不报错。

**约束**：`gsub/gmatch/match` 的 needle 里含 `(` `)` `'` `%` `-` 等字符时
必须 `vim.pesc`（replacement 侧转义 `%%`）；判定"替换/重写生效"要断言旧值
**不再出现**（`select(2, gsub(...))` 计数或全串 equals），不能只 matches 新
值——`matches("``proc_copy`\\(`")` 就放过过 ② 的双反引号。给"纯函数"补测试
时优先全串 equals，子串 matches 只用于宽松冒烟。

## 14. MySQL 种子乱码＝初始化连接 charset，不是插件读取 bug

**发生了什么**：`playground/init/mysql/` 全库（cinema 尤甚）在 dataset 里
中文/日文/西里尔全变乱码。`docker exec ... mysql` 读出来的字节是二次编码：
`外`(`E5A496`) 存成了 `C3A5C2A4E28093`。根因：官方 mysql 镜像
`/entrypoint.sh` 的 `docker_process_sql` 调 `mysql` 客户端**不带**
`--default-character-set`，客户端默认会话 `character_set_client`＝`latin1`
（MySQL 的 latin1＝cp1252，`0x96` 会被 `SET NAMES` 前的中文 UTF-8 字节映射成
`–`），seed 的 UTF-8 字节被 latin1→utf8mb4「解释一次再转存」＝双重编码入库。
文件与建库都是 utf8mb4 也无济于事。poste 的 sqlx 连接默认 utf8mb4，如实读出
坏字节，所以「乱码」在库里不在读取链路。

**约束**：往 `playground/init/mysql|mariadb/` 落任何含非 ASCII 的 seed 文件，
文件首条语句必须是 `SET NAMES utf8mb4;`（纯 ASCII，先于任何多字节字节流）。
新方言 seed 落盘后按第 12 条完整重跑，并抽验一条多字节行：
`SELECT HEX(name_zh)>0 AND name_zh=CONVERT(name_zh USING utf8mb4) ...`。

---

## 15. BINARY 列的乱码在 Rust 值转换里，不在 Lua 侧

**发生了什么**：`game_achievements.hidden_hid`（`BINARY(16)`）在 dataset 里显示
成 `�` 一串。数据本身没问题（`HEX(hidden_hid)` 在 mysql CLI 里是
`8885031DAE8A11F19D8C669C27760320` 这样的 hex）。根因：Rust CLI 的
`mysql_value_to_json`（`poste.nvim/crates/poste-cli/src/{exec_file,session}.rs`
及 `poste-exec/src/sql_executor/{mysql,value}.rs`）对
`Vec<u8>` 走 `String::from_utf8_lossy`，BINARY 的非法 UTF-8 字节在 Rust 侧就被
换成 U+FFFD——JSON 一发出，字节值已经丢失，Lua 拿到坏串无法还原。所以修 Rust，
不修 Lua。修复：给 BINARY/VARBINARY/TINYBLOB/MEDIUMBLOB/BLOB/LONGBLOB 加
`mysql_binary_to_hex` 分支，按 MySQL `HEX()` 习惯输出大写 hex。

**约束**：poste 插件（poste-db.nvim）的查询默认走 `poste session`
（`poste-db/executor.lua` 的 `prefer_session=true`），会话路径是 live 转换器，
exec-file 是 fallback（visual selection 也走 exec-file）。改了其中一个必须同步
另一个；`poste.nvim` 的 `poste-exec/src/sql_executor/mysql.rs`（方言引擎，目前
MSSQL/ClickHouse 在用）还有一份同款转换器，也要一起改（现已经补齐）。
`poste-for-db` 是遗留工作树（已并入 main 且流程已废弃，Rust 改动直接进
poste.nvim main），不要再往里写代码。验证：直接给二进制喂
`{"seq":1,"sql":"SELECT hidden_hid FROM cinema.game_achievements LIMIT 3;"}` 看
返回 JSON，`hidden_hid` 应与 `HEX(hidden_hid)` 一致；改完记得 `cargo build`
重建 `poste.nvim/target/debug/poste`（插件按 rtp 目录解析二进制，不用装）。

## 16. Devanagari 顶掉 dataset 右边框：strdisplaywidth 折叠了 Mc 间隔标记

**发生了什么**：`सिंधु घाटी`（10 码点）被 `strdisplaywidth` 算成 5 格，终端却画
8 格——vim 的 composing 表不区分 Mn 非间隔标记（ं ु，两边都算 0，无害）和
Mc 间隔标记（ि ा ी，终端各占 1 格），凡是含印度语系 Mc 标记的 cell，pad 少补、
行尾 `│` 被字形盖掉，后续列全部错位。CJK-safe 截断救不了：这不是"算 1 实画 2"
（同源偏差），而是 vim 0 vs 终端 1，`strdisplaywidth` 本身就是错的 oracle。

**约束**：dataset 渲染路径的宽度/截断一律走 `lua/poste-db/width.lua`
（`display_width`/`truncate`，按 `width_mode` 在终端口径与 nvim 口径间切换），
不要直接调 `vim.fn.strdisplaywidth`。`MC_FOLDED` 区间表是
"Unicode Mc ∧ 本机 nvim 折叠"的探测产物——vim 未折叠的 Mc 已被它自己算 1，
再修就重复计宽；nvim 捆绑的 Unicode 表升级后需重新生成。回归测试在
`tests/sql/width_spec.lua`（不变量：所有含 `│` 的行 display_width 相等）。
注意 `l:sub(-1)` 拿的是 `│` 的尾字节 0x82 不是字符，断言边框用 `vim.endswith`。

**两套绘制路径（2026-09-13，Ghostty 1.3.1 实证）**：nvim 对同一行有两种
画法——整行首次绘制/滚动进屏是线性写，光标跟随**终端**推进（Ghostty 对
Mc 记 1 格）；光标/高亮触发的**局部重绘**按 nvim 自己的网格绝对定位（Mc
折叠为 0）。两种补位各满足一条路径、各错另一条：按 vim 宽度补 → 首绘右漂
3 格（原始 bug：边框被盖）；按修正宽度补 → 重绘后左移 3 格（"向左缩进"）。
纯 padding 无解，落为 `setup({ width_mode = "nvim" | "terminal" })`
（默认 nvim，与光标/导航/重绘一致；terminal 首绘正确）。教训：A/B 探测表
只能验证首绘路径，"看起来对齐"不代表所有路径都对——判定前先分清用户看的
是哪种绘制。真正的修复在上游（nvim 宽度表对 Mc 的折叠）或 GUI 客户端
（网格即唯一真相）。另外注意：复制到终端外的文本按各自渲染器折叠 Mc，
看起来错位是假象，别据此下结论。

---

## Plenary harness：`after_each` 注册在 describe 外 → 目录模式静默丢文件（2026-09-14）

**发生了什么**：`sql_exec_run_log_spec.lua` 等三个新 spec 把 `after_each(...)`
写在文件顶层（describe 外）。`PlenaryBustedFile` 单跑时测试全绿、仅末尾
打印一条 `Error in command line: busted.lua:147: bad argument #1 to 'insert'`
（`table.insert(current_after_each[#current_description], fn)` 在无 describe
上下文时 `#current_description` 为 nil）；但 `tests/run.sh` 的
`PlenaryBustedDirectory` 下，子进程在汇报前就被这个错误带崩——"Scheduling:"
了却永远不出 "Testing:" 行，84 个文件只剩 81 个跑，且 `run.sh` 只以退出码 1
报错、正文零失败统计，极易误判为"全绿"。

**约束**：`before_each`/`after_each` 必须写在 `describe` 块内（仓库现有 spec
均如此，见 `tests/sql/sql_executor_spec.lua`）。验收目录跑法的结果时要三对：
`grep -c '^Testing:'` == spec 文件数、逐文件 `Failed :` 全 0、`run.sh` 退出码
为 0——只看退出码或只看个别文件的绿字都不够。另外 plenary 在测试生命周期外
触发的 ERROR 级 `vim.notify` 会走错误通道砸中 harness：spec 里驱动异步回调时
（如 `sql_db_browser_introspect_log_spec.lua`）要 stub `vim.notify` 并在测试
存活期内 `vim.wait` 排空 `vim.schedule`，防止跨测试泄漏与 late-callback 崩溃。

---

## 树的顶层 ERROR 兄弟节点同时劈开语句边界，不只污染诊断（2026-09-23）

**发生了什么**：`LIMIT 1, 10`（MySQL/SQLite/ClickHouse 的 `LIMIT offset,count`
分页）在 tree-sitter-sql 里解析成 `limit 1` 语句 + **顶层** ERROR 兄弟节点
`, 10`。按 #11 的套路只给 `find_error_nodes` 加了 dialect 过滤、给
`syntax.lua` 加了去红 matcher——但顶层 ERROR 兄弟节点同时被当"语句"读：
`ts_stmt.lua` 的 `find_stmt_span` 二分取"最后一个起点 ≤ 行的 span"，多行
写法下光标停在 LIMIT 行会把 `, 10;` 当当前语句提取执行；
`find_all_stmt_lines` 把它当独立语句起点，单行写法下还产生重复起始行。
诊断层修完，执行层还在坏。多数已知误报（INTERVAL、digit 前缀、WITHIN
GROUP）是**嵌套** ERROR，只有顶层兄弟才劈 span，所以这坑此前没暴露——
`; USE` 级联、ClickHouse ALTER DELETE 的谓词也是顶层兄弟，同样受影响。

**约束**：加"顶层 ERROR 兄弟"类过滤器时，同一形状判定要在三个消费点对齐：
`find_error_nodes`（诊断，dialect-gated）、`build_span_list`（当前语句
span，合并进前一个 span 而非跳过）、`get_top_level_stmts`（语句起始行，
跳过）。探针除了 dump ERROR 的 text 还要 dump 顶层 children，先分清 ERROR
是嵌套还是兄弟；带 `;` 与不带 `;` 各探一次——无 `;` 时 ERROR 会吞掉下一条
语句（`, 10 SELECT 2`），锚定匹配让它保持报错。

## 19. 用脚本重写 Lua 源码，先过不了 luacheck 别说改完了

**发生了什么**：给 117 处 `vim.notify` 批量补 `{ title = "PosteDb" }` 时，
第一版脚本用"找 `vim.notify(` + 括号配平"定位调用——把 **docstring 注释里的
`vim.notify(…, INFO/WARN)`** 也当调用，括号配平从注释一路吞到很远，整段
源码被替换成一行（source_format.lua -451 行，共损毁 -7420 行）。第二版修了
注释识别，但 `scan_calls` 返回的 end 已越过右括号、调用方又 `end+1`，生成
`vim.notify(..., LEVEL), { title = ... })`——title 落到调用外，仍是语法错误。
两次都靠 `git diff --stat` 的异常删除量才发回。

**约束**：批量重写源码的脚本必须（1）全文件词法状态机（code/string/
long-string/comment/block-comment）而不是"find + 配平"；（2）对每个重写
产物自检——重新 lex 一遍必须恰好得到它自己；（3）apply 后**立刻**
`luacheck` + `loadfile` 全树语法扫描，不要等测试；（4）动手前
`git status` 必须干净，损坏时 `git checkout -- <files>` 回滚的是脚本碰过
的文件集合，要防止把同文件里的手工修复一起回滚丢掉（本次手工修复被迫
重放两次）。

## 20. autocmd 回调按"内容等价"去重：靠实例闭包做 per-instance 注册是死路

**发生了什么**：给 `statusline.lua` 的 per-connection 高亮缓存加 ColorScheme
失效时，drop 回调写成了实例闭包（`callback = function() hl_cache = {} end`，
重新绑定模块局部 `hl_cache`）。spec 环境会 reload 本模块（mini-wiring 测试
`package.loaded[...] = nil` 再 require），实测：reload 后的新实例走
`nvim_create_autocmd` 全程无报错、组 id 相同，但 `nvim_get_autocmds` 里**永远
只有一个 handler**——本机 Neovim 对内容等价（常量折叠后相同）的回调去重，后
注册的静默丢弃。于是无论 `clear = true`（最后一个实例清掉前面所有实例的
handler，旧实例缓存永不失效）还是 `clear = false`（只有第一个实例的缓存会失
效），总有一部分实例的缓存在 `:colorscheme` 后永久过期。隔离单跑、手工探针
全部无法复现，只有"先跑一遍会 reload 的测试再跑缓存测试"的完整文件才稳定
复现。

**约束**：跨 reload 生效的状态不能用实例闭包承载——失效句柄要落在 reload
存活的地方（`vim.g` 计数/epoch 是首选），数据侧每条缓存带 epoch、读取时比
对，handler 只负责 bump。写依赖 autocmd 注册时序的测试前，先用
`nvim_get_autocmds` 数一下实际注册数，别信 `create_autocmd` 的返回值；一个
"隔离跑必过、全量跑偶挂"的失败，先怀疑同文件更早测试留下的注册/状态。

## 21. 给"被桩的模块"提升 require，全量门是绿的，单文件跑才炸

**发生了什么**：round 57 把 `nav/handlers.lua` 的 `require("poste-db.context")`
从函数体内提升到模块顶层（配合新的 `context.detect_command`）。
`sql_nav_spec.lua` 用 `stub_module("poste-db.context", ...)` 在测试体里替换
`package.loaded`，但 spec 文件顶部早就 `require("poste-db.nav")`——顶层
require 让 handlers 在**那一刻**捕获了真模块，桩永远落不进去。更隐蔽的是：
全量 `tests/run.sh` 是**绿的**（别的 spec 先加载了真 `poste-db.context`，
`stub_module` 保存/恢复的本来就是真模块，行为碰巧一致），只有
`tests/run_one.sh tests/sql/sql_nav_spec.lua` 单文件跑才红。同一天还有第二
个变体：`sql_nav_spec` 给 `poste-db.util` 的兜底桩是手写的假模块
（`{ clean_nil = ... }`），nav/detect 一旦开始调用 `util.unquote_ident`
就 nil 索引——同样是单文件跑才炸（全量跑时 util 已被加载，兜底分支没走到）。

**约束**：(1) 给一个"有 spec 通过 `package.loaded` 桩它"的模块新增顶层
require 前，先 grep 那个模块的 spec 找 `stub_module`/`package.loaded`；
约定俗成的规则是 handlers 层保持惰性 require，并在文件头注释里写明为什么。
(2) 给叶子模块写兜底桩时回退到真模块（`saved or require(...)`），不要手写
假模块——假模块在真实模块长出新函数那天变成 nil 索引。(3) 改动涉及 require
结构时，单文件跑一次受影响的 spec 是必要验收，全量绿不算数（两个环境在
`package.loaded` 的预填充状态上不等价——`tests/run_one.sh` 头注释记录过
另一个实例）。

## 22. Lua 负索引从尾部数：`s:sub(1, cut)` 的 cut 必须先钳非负

**发生了什么**：`util.utf8_safe_cut`（`lua/poste-db/util.lua`）在预算超过串长
时直接 `s:sub(1, cut)` 截断。调用方传进 `max_bytes = -1` 时，`#s <= max_bytes`
为假、`while cut > 0` 直接跳过，`("abc"):sub(1, -1)` 按 Lua 语义返回
`"ab"`——负数下标从**尾部**数，-1 是"去掉最后一个字符"而不是"什么都不要"。
调用方要截断、函数却几乎原样返回，且无任何报错（2026-10-19 检视中发现，
修复为 `max_bytes <= 0` 先返回空串）。

**约束**：任何 `string.sub`/`string.byte` 的位置参数可能为负（来自计算、
配置或外部输入）时，先钳到合法区间再下标。同类陷阱还有 `s:sub(i, j)` 在
`j < i` 时返回空串（无害）与 `("abc"):sub(2, -2)` 返回 `"b"`（把"中间段"
写成了"去掉两端"）。审这类代码时专找 `sub(1, <变量>)` 且变量没有下界保护
的位置。

## 23. 判死代码前，从 require 行推出全部别名，不要猜别名名

**发生了什么**：2026-10-24 审查里，子代理判定 `constants.lua` 的
`M.TITLE = M.PLUGIN_TITLE` 别名"零使用"。复核发现 `buffer/` 子树有
12+ 处在用——但都是 `C.TITLE` 形态，因为那些文件写的是
`local C = require("poste-db.constants")`。子代理 grep 的是
`const.TITLE` / `constants.TITLE`（猜的别名名），本仓库同一模块在
不同文件里至少有 `C`、`const`、`constants`、`core_util` 四种别名
（`state` 还有 `sql_state`/`poste_state` 两个）。

**约束**：宣布一个 `M.x` 导出死之前，先
`grep -rn 'require("poste-db.<mod>")' lua/` 拿到**全部**绑定的局部名，
再逐个别名 grep `别名.x`。猜别名名等于只搜了符号空间的一个子集；
harness 里"Grep both shapes"的 local alias 一指，落地动作就是这一步。

---

*Latest: 2026-10-24 审查会话（#23 从 require 行推别名）。
新增条目时保持同一格式：发生了什么（带 file:line）→ 约束（可执行的检查动作）。*
