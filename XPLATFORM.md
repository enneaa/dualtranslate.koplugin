# DualTranslate 跨平台改造说明（v1.2.11-xp32，原名 KoTranslate）

xp39（全面检查修复）：
1. 真 bug：buildProviderSelector 的 text_func/callback 捕获 Lua 5.1 循环
   变量 provider（循环体内未拷贝）——所有"翻译服务"菜单行会显示同一个
   （最后一个）服务名。修复：局部拷贝 pid/pname；顺带删除冗余的
   enabled_func（菜单项默认启用）。
2. 真 bug：ButtonDialog 没有 text/info_text 字段（KOReader 标准字段是
   title + _added_widgets）——"取消翻译"和"清除本书译文"两个对话框的
   描述文字实际不显示。修复：描述并入 title（TextBoxWidget 自动换行）。
3. 删死代码：getInlineFontPercent（无调用点）。
4. 删死 CSS：.dualtranslate-translation 规则（显示控制已由 overlay
   ::after 的 translation_visible 承担，插件启停同样走 buildCss 省略
   ::after 规则）。
5. 清理：修"清除本书译文"菜单项缩进；删 translate_microsoft_free_batch
   调用多余参数 (nil, {})；删 reader.lua 顶部死 require Epub。
验证：加载级测试（init + 菜单构建 + 全项渲染 + 断言两个服务名独立显示）、
cache mock、语言子菜单、方法调用完整性、luac 全量——全过。

xp38（修复打开菜单闪退）：根因 = buildLanguageMenu 的
`for _, lang in ipairs(Languages.list)` 循环变量 `_` 遮蔽了 gettext `_`，
循环体内 `_(name)` 实际在调用数字（当前迭代索引），Lua 直接报错；而
语言菜单项用 sub_item_table 立即求值（addToMainMenu→buildMenuTable），
每次打开"工具"菜单都会执行 → KOReader 捕获 Lua 错误后 abort
（Android logcat 见 I/libc: handling signal 6）。xp36 引入、xp37 继承。
修复：循环变量 `_` 改 `__`（保留丢弃语义，不再遮蔽 gettext）。排查
方法：KOReader API stub 环境真实加载全部模块 → init → addToMainMenu →
逐项渲染 text/checked/enabled_func + 子菜单递归，完整复现崩溃路径；
并用脚本全库扫描"for _ 循环体/闭包内调用 _()"（其余 24 处 for _ 均
安全：循环体内无 gettext 调用）。新增回归：加载级菜单构建测试
（/tmp/loadtest.lua，需重跑时重建）。其余验证：luac 全量、cache
mock、语言子菜单闭包、方法调用完整性——全过。

xp37（全模块再精简 + 命名对齐）：cache.lua 提炼 _query/_execute
两个 SQL 辅助，lookupForBook/lookup/storeForBook/store 两对重复的
prepare/bind/step/close 各缩成 3 行；clearForBook 删除旧版本 NULL
book_path 全局行逐条修补循环（新版不可达、纯历史包袱）；加 unpack
兼容行（Lua 5.2+ 移入 table，LuaJIT 5.1 全局，两边都稳）。main.lua
删除越权改写 KOReader 全局 httpinspector 的启动副作用；clearForBook
调用去多余参数。epub.lua 的 DataStorage/socket.url 提为顶部 require，
手写 url_decode 换原生 socket.url.unescape。命名对齐实际功能：
isBilingualEpub→isLegacyBilingualEpub、getBilingualCacheDirectory→
getBookCacheDirectory、removeBilingualFilesForBook→
removeTranslationFilesForBook、toggleBilingualMode→toggleTranslationVisible；
删除纯包装函数 refreshCurrentBilingualStyle（6 处调用直连
refreshDocumentStyles）。保留并说明：rmtree（util.removePath 只删空
目录）、stable_path_hash（util.md5sum 仅对文件）、EPUB 正则解析
（CREngine/luxl 无文本注入 API，流式 XML 重写风险大于收益）、
html_to_text（util.htmlToPlainText 不保留 br→换行/rt 剔除语义）、
进度/取消文件与队列独立文件（Trapper IPC 与动态运行数据）。
验证：luac 全量、cache mock（SQL 目标/绑定数/未命中/清理）、语言
子菜单闭包回归、方法调用完整性。净减 153 行（3452→3299）。

xp36（语言选择改通用子菜单组件）：源/目标语言从弹独立
Menu 对话框改为主菜单 sub_item_table 子菜单 + radio 单选（对齐
translator_switch 的 genLanguagesMenu 模式）：点开即选、即时生效、无需
确认提示，父菜单项下次打开自动显示新值；源语言首项"自动识别 (auto)"；
语言名经 gettext _() 本地化（按界面语言显示）；删除 showLanguageSelector
独立对话框构建及其 Device/Screen require。验证：luac、语言子菜单闭包捕获+
radio+每行独立 key 模拟测试、方法调用完整性。

xp35（界面组件全面换原生）：①翻译进度对话框从 InfoMessage+
手绘 █░ 文本条 换成 KOReader 原生 ProgressbarDialog（OTA 更新同款：
原生进度条 + title 百分比 + subtitle 明细，reportProgress 驱动；点按直接收起、
任务继续，可从队列菜单重开）；②全部轻提示（翻译完成/取消/中断/
队列操作反馈）从模态 InfoMessage 换成非模态 Notification toast，不再
打断阅读；③删除因此不再使用的 require（reader 的 Device/Screen）。
评估后保持的：主菜单平铺（KOReader 插件标准信息架构，12 项含动作与
设置，ConfigDialog 适合独立偏好面板反而绕）；队列界面 Menu+ButtonDialog
确认、语言选择 Menu、译文字体通用菜单、TextViewer 译文视图、InputDialog
均为原生组件。验证：luac 全量、方法调用完整性、splitTranslationText/
cssFontFamily/stable_path_hash/dump round-trip 回归全过。

xp34（更多原生替换）：①队列持久化改用 KOReader 原生 dump 序列化器
（删 25 行手写序列化，写出的文件仍是合法 Lua、dofile 读回，兼容旧文件）；
②pagetrans 删除重复的本地 OverlayLoad，统一用 overlay.lua 的 Overlay.load；
③Tools.mkdir_p 改用 KOReader 原生 util.makePath（删 17 行手写递归）；
④局部 trim_text 改用原生 util.trim。其余保持自研的部分均为 KOReader 无
原生等价物：Trapper 子进程通信必须用文件（进度/取消标志）、队列属动态
运行数据不宜放 settings.reader.lua、EPUB spine XHTML 提取与逐章 DocFragment
探测无现成 API、递归删除无原生实现、stable_path_hash 无字符串哈希 API
（util.md5sum 仅对文件）、网络层本就是原生 socket.http/socketutil。
验证：luac 全量、dump round-trip（中文路径/反斜杠/布尔/数字/旧格式兼容）、
splitTranslationText UTF-8、cssFontFamily、stable_path_hash、方法调用完整性。

xp33（删译文字体子菜单多余分隔线）。

xp32（整体精简与原生替换，-488 行）：①配置系统迁移到 KOReader 原生
G_reader_settings（settings.reader.lua，dualtranslate_ 前缀），删自写 serialize/
saveConfig/getConfigPath；State.loadConfig 只做一次性迁移：读旧
settings/dualtranslate.lua 与插件内 dualtranslate_configuration.lua，写入
G_reader_settings 后把旧文件改名 .migrated；getSetting/saveSetting 全部走
原生 API。②删除旧"生成双语 EPUB"体系（prepareBilingualProgress /
syncBilingualProgress / getBilingualSourcePath / getExistingBilingualPath /
autoOpenExistingBilingual / scheduleBilingualProgressSync / find_numbered_epub /
getBilingualCachePrefix，约 200 行；保留 isBilingualEpub 防御，
removeBilingualFilesForBook 简化为只删本书 overlay 缓存目录），isTranslationManagedBook
改为查 overlay 是否存在（不再每词翻译探测 100 个文件）。③删死代码：
showTranslateInput / unzip_list / read_zip_entry / path_exists / getStats /
translateTextBatchForEpub 不可达的 system 分支；④stable_path_hash 去重
（并入 dualtranslate_tools.lua）；languages 加 code→name 索引；getProviderName
未知模式回退文案修正；清理无用 require。验证：配置迁移 4 场景模拟、
splitTranslationText UTF-8 完整性、cssFontFamily 引号、buildCss 注入、进度格式、
stable_path_hash、全部方法调用完整性（self/plugin/Cache/Epub）、luac 全量。

xp31（译文字体改用 KOReader 通用字体模块）：撤掉 xp30 硬编码的字体选项列表，改
用 KOReader 自己的字体注册表——require("document/credocument"):engineInit()
+ cre.getFontFaces()（与「版面→字体」菜单同一数据源），列出设备上实际
可用（含用户放入 fonts/ 目录）的 CREngine 字体族；显示名优先用
FontList:getLocalizedFontName 本地化名（照 readerfont.lua 标准做法）；
菜单改为 sub_item_table_func 懒加载（只在打开子菜单时枚举）；无 cre 引擎
时降级为「跟随段落 + 自定义」。新增 Overlay.cssFontFamily：多词字体名
自动加引号、CSS 通用族（serif/sans-serif/monospace）保持不加引号、
已加引号的原样保留，注入 ::after 与 .dualtranslate-translation 两条 CSS
路径。分隔线改用 KOReader 标准 separator=true。验证：CSS 序列化 6 用例、
菜单构建含去重/闭包捕获/降级、luac 全量、self 调用完整性全过。

xp30（新增译文字体选项）：译文此前只设颜色和字号、字体跟随原段落
（font-family 继承）。新增「译文字体」菜单（位于译文字号与译文颜色
之间）：
- 跟随段落（默认，空值：不注入 font-family，继承所在段落字体）；
- 无衬线 sans-serif / 衬线 serif / 等宽 monospace；
- Noto Sans CJK SC（无衬线中文）/ Noto Serif CJK SC（衬线中文）；
- 自定义字体…（InputDialog 输入任意 CSS 字体栈，如
  "Noto Serif CJK SC, serif"）。
实现：Overlay.buildCss 的 ::after 规则与 refreshDocumentStyles 的
.dualtranslate-translation 类同时注入 font-family；取值经
`gsub("[;{}]")` 清洗防止手改配置破坏样式表；configuration*
默认新增 ["inline_font_family"] = ""。验证：CSS 输出断言
（默认无 font-family / 自定义注入 / 隐藏不输出 / 清洗）通过，
luac 全量语法、self 调用完整性通过。

xp29（全面精读 + 逻辑模拟 + 修复，一步到位）：逐文件全文精读全部 13
个模块（3616 行），对照 KOReader 源码验证 API
（CreDocument:setStyleSheet(css, extra) / UIManager:setDirty lambda /
Trapper:dismissableRunInSubprocess / Translator:translate 签名），
编写可执行模拟验证（闭包语义、章节探测、UTF-8 分块、原子写），修复：

1. **Lua 5.1 循环变量闭包陷阱（3 处真 bug）**：
   - showQueue：每行"取消翻译"回调捕获 for 循环变量 item，多任务排队时
     全部指向队列最后一项 → 取消错任务。循环内改捕获 item_copy。
   - inlineStyleMenu（译文颜色子菜单）：checked_func/callback 捕获
     choice → 所有颜色项实际都是最后一种颜色。改捕获 value/label。
   - showLanguageSelector：callback 捕获 lang → 语言列表所有行都写入
     最后一种语言。改捕获 code/name。
   （验证脚本逐项断言 ABC/多值捕获正确。）
2. **currentChapterIndex 性能**：原实现每次翻页全量探测 1..512 个
   DocFragment（200 章书 = 每翻一页 200 次 getPageFromXPointer）。
   改为缓存 page→index + 从缓存位置双向渐进探测：普通翻页 2-3 次探测
   （约 100 倍提升），大跳转才退化为全量（仍限 512）；关书时清缓存。
3. **splitTranslationText 切坏 UTF-8（真 bug）**：CJK 无空格长段落按
    limit 硬切时会把多字节字符拦腰截断（前段以悬空起始字节结尾、后段
    以 continuation 字节开头）。修复为 to_char_boundary：回退到字符
    起始字节后再回退一字节。验证：长 CJK / 中英混排 / 英文 / 4 字节
    emoji 用例全部字节完整。
4. **缓存库损坏容错**：SQLite 文件损坏（断电/异常退出）时 SQ3.open /
   prepare 抛错会直接崩插件。Cache:open 改为 pcall + 损坏重建
   （删 db/-wal/-shm 重开），lookup/lookupForBook/store/storeForBook/
   getStats/clear/clearForBook 全部降级为缓存未命中并记录日志，不再
   可能崩溃。
5. **缓存元数据**：translateTextBatchForEpub 在 system 模式把缓存
   provider 写死为 "microsoft_free" → 改为记录实际使用的 mode。
6. 维护：onCloseDocument 清 _chapter_index_cache；epub 死 require
   （lfs）清理（xp28）。

验证方式：luac 全量语法；xp29 模拟脚本（闭包三场景 + 章节探测 8 场景
含同页缓存/前进/回退/跳转/探针计数）；split 真实函数字节完整性
（含 4 字节 emoji）；self 调用完整性全过；KOReader API 签名对照。

xp28（与原版逐函数回归对比）：将当前全部代码与原版
kotranslate.koplugin.zip 逐模块、逐函数体对比（含提取工具修正
`%w` 不含下划线导致的函数名截断问题），结论：

- **本次对比确认无其他改坏**。原版 50 个 reader 函数、37 个 main
  函数逐一核对：删除的均为辅助阅读/注音/Kindle shell 专用（assist
  系列、paintTo、resetRubyPaintCache、build_epub_archive、
  inject_after_tag、update_style、translate_document 等，共 20+ 个，
  全部无残留调用）；保留函数的改动全部为预期演进（前缀改名、跨平台
  shell→Tools.mkdir_p/rmtree、队列加 span/silent/auto、watchdog、
  配置迁移、防御性防损坏条目）。
- 自动交叉验证全过：`self:xxx` 调用 100% 有定义；所有 require 的
  dualtranslate_* 模块存在；kotranslate 标识无残留；lfs 引用与
  require 配对；pagetrans 的逐章方法经 attach 挂载齐全。
- 顺手清理：epub 模块 1 个死 require（lfs，从未使用）。
- 已知行为差异（非 bug）：当前 looks_translatable 允许单字符段落
  翻译（原版要求 ≥2 字符），更宽松、不漏译；旧版缓存目录
  kotranslate→dualtranslate 不迁移（用户拍板不向前兼容），旧书译文
  需重新翻译。

xp27（修复 Epub boolean 崩溃——真正根因）：xp26 改名后用户仍报同样的
`attempt to index upvalue 'Epub' (a boolean value)`。深入比对发现：

- **直接根因**：`dualtranslate_epub.lua`（原 `epub.lua`）被裁剪时丢失了
  文件末尾的 `return Epub`。Lua require 对无 return 的模块返回 **true**
  （boolean），于是 `Epub.translate_overlay` 必然崩溃。原版 epub.lua
  第 989 行有 `return Epub`，裁剪版（删除 Kindle shell 依赖、辅助阅读、
  旧改书管线后）漏补。已本地用 Lua 实测确认「无 return 模块
  require 返回 boolean:true」。
- 顺带把主流程改为三重保险：main.lua 启动时 `loadEpubModule()`
  （require → 失败则从 `self.path` 绝对路径 dofile，绕开 package.path
  污染）缓存到 `self.epub`；reader.lua 调用前再兜底一次；若仍缺失，
  弹窗给出明确中文诊断而非 cryptic 崩溃。
- 全量核对：其余 12 个模块尾部 return 均完整；epub 模块内容为
  原版按新架构裁剪（shell 命令、辅助阅读、旧改书管线、count_translatable
  均已随各自轮次移除），函数清单与调用方匹配。

xp26（修复 epub 模块名冲突，保留为防御层）：用户报错
`attempt to index upvalue 'Epub' (a boolean value)`，根因：

- KOReader 在加载完所有插件后，把**全部插件目录**按路径字符序永久加入
  `package.path`（pluginloader.lua）。插件自己的模块如果叫裸名
  `epub.lua`，`require("epub")` 会解析到**字符序靠前**的、同样带
  epub.lua 的任意插件——返回的可能是别的模块（甚至非 table），
  `Epub.translate_overlay` 即崩溃。
- 原版 Kotranslate 在 Kindle 单插件环境无冲突；多插件环境下这是必然
  隐患。xp22 改名时其余 11 个模块都带 `dualtranslate_` 前缀，唯独
  `epub.lua` 保留裸名。
- 修复：`epub.lua` → `dualtranslate_epub.lua`，main/reader 的
  `require("epub")` → `require("dualtranslate_epub")`；同时删除 main.lua
  中未使用的 Epub require。所有自有模块现均已带唯一前缀，与其他插件
  完全隔离。
- 升级注意：旧版解压出来的 `epub.lua` 不再被引用，建议整目录替换
  插件（删除旧 `dualtranslate.koplugin` 目录后再解压新包），避免残留。

xp25（全面复查与修复）：逐文件通读全部代码后的完整复查，修 1 个关键
崩溃、2 个行为问题，并清理大量死代码：

- **关键崩溃修复**：恢复被 xp22 误删的 `looks_translatable`。该函数被
  `collect_overlay_candidates` 调用（epub.lua），缺失会让所有整书/逐章
  翻译在收集段落时崩溃（`attempt to call a nil value`），错误被兜底文案
  掩盖（即 xp24 之前看到的「无法生成本书译文缓存」类现象）。已恢复
  实现并删掉无引用的 `count_translatable`。
- **overlay 原子写**：`write_file` 原来先 `os.remove(path)` 再
  `os.rename`，检查点写盘存在「旧文件已删、新文件未就位」的窗口；改为
  直接 rename 覆盖（POSIX 语义），崩溃时保留上一份完整 overlay。
- **续翻完成弹窗降噪**：逐章模式自动续翻的章节完成任务后不再弹
  「翻译完成」toast（进度对话框仍显示——这是用户明确要的），仅手动
  启动的任务弹完成提示。实现：enqueue/translateBook 增加 `auto` 标记，
  随队列持久化。
- **双语进度循环停止空转**：`scheduleBilingualProgressSync` 原来对任何
  打开的书每 15 秒空转一次；现在仅旧双语伴侣书继续循环。
- **死代码清理**：删除无引用函数（`Tools.find_binary`+binary_cache、
  `LanguageUtils.getSortedNames/getCodeNamePairs/getCodeByName`、
  `toggleCache`、`count_translatable`）与 9 个无引用 require
  （main/reader 中的 Geom、GestureRange、Event、FileManagerUtil、
  InputContainer、T 及旧注音浮层残留 Font/RenderText/Blitbuffer）。
- **队列失败项**：错误文本（可能带堆栈）截断到 56 字符，队列菜单保持
  可读。
- **文档与配置**：README 修正默认服务描述（实际默认 system 而非 Edge）、
  配置实际路径说明；配置样例清除 ktranslate 残留并统一 target_lang；
  tools.lua 头部注释清除 sdcv/zstd/tar 过时描述。
- 冒烟测试：对 looks_translatable / fragment 解析 / 超长文本分块做
  独立验证，全部通过。

xp24（修复"无法生成本书译文缓存"与翻译取消失效）：用户报告整书翻译
提示"无法生成本书译文缓存"，排查定位两处根因：

- **参数错位（严重）**：`_runTranslation` 调用 `Epub.translate_overlay`
  时多传了一个 `nil` 占位，导致签名中的 `span` 被赋为 nil、`cancel_path`
  被赋为 `item.span`、真正的 `.cancel` 路径被丢弃。后果：整书/逐章任务
  的取消完全失效（取消标志文件无人检查）；逐章任务 `cancel_path=1`
  会让 `io.open(1)` 抛错，整章任务直接失败。已修正为
  `output_dir, item.span, progress_path .. ".cancel"`。
- **错误信息被吞**：Trapper 子进程里 `task()` 无 pcall 包裹，初始化环节
  （语言/路径/提供器取值）一旦抛错，子进程静默无输出，父进程拿到
  `result=nil` 只显示兜底文案「无法生成本书译文缓存」，真实原因丢失。
  已把 worker 整体包进 pcall，任何初始化错误都会作为可读错误返回；
  `result=nil` 兜底文案改为「翻译进程未返回结果（可能内存不足或进程
  被终止），请查看日志后重试」。
- **内存峰值**：整书翻译此前把全部章节的候选段落一直驻留到运行结束，
  大书会抬升子进程内存水位（子进程被杀是 result=nil 的常见来源）。
  现改为每章翻译完立即释放该章候选（`release_chapter`），行为不变。

xp23（继续优化复查）：静态复查全部代码后的收尾优化：

- 删除 `State.enqueue` 中永远不可达的第二个同书检查（首个循环已覆盖
  queued/active 任意类型任务），连带删除无引用的 `State.findQueued` 及
  attach 绑定。
- 清理过时注释：`dualtranslate_reader.lua` 的 pronunciation ruby 注释块、
  `dualtranslate_overlay.lua` 的 "Translations and pronunciation lines"。
- `write_progress` 增加 0.25s 节流：整书翻译原本每段落 open/write/close
  一次进度文件，数千段即数千次文件 IO；节流后约 4 次/秒，进度对话框
  轮询 0.5s，平滑度不受影响，watchdog（10 分钟 mtime）不受影响。首次
  调用强制写，保证进度文件立即创建。
- 翻译完成弹窗：有失败段落时追加「失败段落将在下次翻译时自动重试」，
  避免整书/章节未全量完成时误读为完全成功。

xp22（去除辅助阅读 + 彻底改名 DualTranslate）：按用户决策，辅助阅读与
翻译功能无关（一个走网络翻译 API、一个走本地词典），最终选择**直接去除
辅助阅读**，插件全面改名 **DualTranslate**（不保留向前兼容）：

- 删除辅助阅读全部功能：菜单项（辅助阅读/辅助阅读设置/下载词典）、
  运行时浮层注音（computeReadingHints/paintTo/_reading_hints 绘制）、
  行距调整、sdcv 词典管理与下载、注解缓存（annotations 表）、epub 内联
  注音死代码、`assist_*` 配置项。
- 删除文件：kotranslate_assist.lua、kotranslate_dictionaries.lua、
  kotranslate_kanji_readings.lua。
- 全面改名（不保留旧标识）：插件名/菜单名 DualTranslate；类名
  dualtranslate；文件 kotranslate_*.lua → dualtranslate_*.lua；缓存库
  dualtranslate_cache.sqlite3；覆盖层目录 cache/dualtranslate/；
  CSS 类名 .dualtranslate-translation；文档与日志前缀全部同步。
  旧版缓存/配置不迁移。
- 保留全部翻译能力：整书/逐章翻译、队列与取消、双语对照显示、
  译文样式设置、按书缓存。

xp21（辅助阅读开关外置）：按用户要求把「启用辅助阅读」开关从子菜单
挪到主菜单层，与「中文翻译」同型：

- 主菜单「辅助阅读」直接是纯勾选项（checkbox + callback，无子菜单），
  普通点击切换 assist_reading，勾选状态直接可见。
- 设置（字号/颜色/英文/日文）拆到独立的「辅助阅读设置」子菜单项。
- 拆分的技术原因：KOReader 中带 sub_item_table 的项点击一律进入子菜单、
  勾选框只显示不可切换（xp4 已验证），所以开关与设置必须拆成两个平铺项。
- 保留行为：勾选注音类型会连带打开主开关。

xp20（修复辅助阅读开关交互缺陷）：辅助阅读菜单主项没有勾选框，启用/
禁用藏在长按手势里，点击只进子菜单——用户既看不到启用状态、也发现不了
切换方式（与 xp4/xp5 修过的「启用插件」同款缺陷）。修复方式与插件主
开关一致：

- 子菜单第一项新增「启用辅助阅读」纯 checkbox，普通点击直接切换
  `assist_reading`，切换后立即刷新行距/注音缓存/当前页提示。
- 主项改为动态文案：「辅助阅读（已启用）」/「辅助阅读」，不进子菜单也
  能看到开关状态；点击仍进入子菜单（字号/颜色/英文/日文设置）。
- 保留原有行为：勾选任一注音类型（假名/罗马音/英文级别）会连带打开
  主开关。

xp19（再检查修复：跨书残留、队列显示与清理）：复查续翻与队列链路后
修复 5 处。

- **修复：关书后续翻状态残留到下一本书**。onCloseDocument 只清了 overlay
  缓存，`_page_translation_follow_active` / `_page_translation_last_fragment`
  未清——上一本书激活过续翻后，打开新书翻第一页就会自动翻译新书。
  关书时全部清理。
- **修复：章节解析不可用时反复翻译第 1 章**。currentChapterIndex 探测
  失败时 fragment 为 nil，同章去重判断失效，每次翻页都会重复入队第 1 章
  （幂等但空转+弹框）。改用哨兵值去重：解析不可用时同章也只触发一次。
- **修复：队列列表把已完成任务显示为"失败"**。done 任务保留在内存队列，
  列表展示未过滤，状态映射落在 else 显示"[失败]"。列表跳过 done 项；
  任务完成时直接从内存队列移除（磁盘本就跳过），避免每完成一个任务
  积累一条死数据。
- **修复：异常中断残留取消标志文件**。Trapper 子进程异常退出
  （completed=false）不清理 `.cancel` 标志文件，会留给后续任务。
  该分支补清理。
- **修复：取消任务后队列菜单残留过期条目**。取消回调先关闭队列菜单再
  移除任务，避免已取消的任务仍显示在列表。
- 核对确认无问题：InfoMessage.onCloseWidget 默认实现存在（进度框收起
  安全）；reopenTranslationProgress 判空完整；同书互斥对 failed 项不
  拦截（保留重试路径）。

xp18（修复续翻失效 + 续翻显示进度）：用户实测反馈两个问题，均修复。

- **修复：翻译一章后不再续翻、再点提示"已翻译完成"**。xp17 的章节任务
  在完成时把 overlay 标成 complete=true（save_checkpoint 按失败数判断），
  而 complete 的含义是"整本书已翻完"——单章翻译完成后，翻页续翻的
  complete 检查直接返回、点「翻译本书」也提示已翻完，续翻彻底失效。
  修复：**只有整书任务（all_chapters=true）且零失败才标 complete**；
  章节任务永远保持 incomplete。续翻的停止改由"翻到最后一章"判定：
  translate_overlay 返回 `last_chapter`（本次任务最后一章 ≥ spine 总数），
  完成时若已到最后一章则结束续翻会话。
- **修复：翻页续翻没有进度显示**。xp13 起翻页自动续翻走静默（无进度框）。
  改为非静默：进入新章节自动翻译时，显示与手动点击相同的进度对话框
  （可点按收起，任务继续），完成时显示结果提示。
- **顺带优化：同章翻页去重**。记录上次触发续翻的章节，同一章内反复翻页
  不再重复入队/弹提示（原实现靠队列幂等兜底，仍会空转一次）。
- 已产生的遗留数据：xp17 时期误标 complete=true 的 overlay，重新点一次
  「翻译本书」（整书模式）会以整书任务重跑并正确重置标志。

xp17（入口收敛 + 队列可取消）：按用户定稿设计改造。

- **菜单只剩一个翻译入口**：「翻译本书」+「逐章模式」勾选，替代原来的
  「翻译整本书」+「逐章翻译」两个并列入口。
  - 未勾选「逐章模式」：点「翻译本书」= 整本书全部翻译（原行为）。
  - 勾选「逐章模式」：点「翻译本书」= 从当前章节开始逐章翻译（正常进度
    框），并激活续翻——之后翻页/跳转到新章节时自动静默翻译该章，整书
    翻完后自动停止。勾选本身不触发翻译；取消勾选立即停止续翻。
  - 逐章模式下若本书已整本翻完，点击提示「本书已翻译完成」。
- **翻译队列可取消**：队列从静态文本弹窗改为可交互列表（书名 + 状态 +
  进度），点击任务弹确认框。
  - 排队/失败中的任务：确认后直接从队列移除。
  - 翻译中的任务：写入取消标志，子进程在当前批次完成后停止（KOReader
    Trapper 子进程无法硬杀，最迟一个批次 ≈ 48 段内生效），已翻译部分
    保留在 overlay 中，可随时重翻。
- **同书互斥**：同一本书无论整书/逐章，队列中同时只允许一个未完成任务，
  重复点击提示已在队列，避免重复工作。
- 底层复用不变：overlay 幂等合并、断点 checkpoint、静默续翻语义。

xp16（全面评估收尾）：逐模块重审全部 17 个 Lua 文件后修复三处一致性问题。

- **目标语言可选项补齐**。语言表原本只有笼统的 `zh`（Chinese），但默认
  目标语言是 zh-Hans，导致菜单显示「目标语言：zh-Hans」原文、且选择器里
  选不了简体/繁体。补充 `zh-Hans`（简体中文）/ `zh-Hant`（繁體中文）两个
  条目：默认值有名字可显示、选择器可选、system 引擎自动归一化
  （zh-Hans→zh、zh-Hant→zh-TW）不变。
- **清除缓存统计补全**。getStats 只统计选中文本翻译表，整书翻译的
  book_translations 表不计入，清除对话框的数字偏小。改为两表合计。
- **打包默认配置与文档对齐**。内置 dualtranslate_configuration.lua 仍是
  mode=microsoft_free、target=zh（旧默认），与新装实际行为（xp8 起默认
  system、xp6 起默认 zh-Hans）不一致。改为 mode=system、target_lang=zh-Hans。
  仅影响全新安装；已有用户的 settings 配置优先，不受影响。
- 重审确认无新增 bug 的模块：overlay（CSS 转义/原子写）、providers
  （system 逐段 + Edge 批量+单条回退）、cache（WAL/按书隔离）、tools
  （路径穿越防御）、dictionaries（下载/解包状态机）、assist（sdcv/注音）、
  epub（resolve/候选收集/checkpoint）、reader（_runTranslation 全分支）、
  state（队列全链路防御，xp15 已加固）。

**已知限制**：逐章翻译（overlay 管线）只生成译文层，不带辅助读音
（假名/罗马音/IPA）——assist 注解层只在整书翻译的旧内联路径生成。
如需要给逐章译文也加注音，属功能扩展而非 bug。

xp15（再检查修复：队列启动层防御 + 选中文本翻译崩溃修复）：系统性重审
发现并修复两处问题。

- **修复（真 bug）：选中文本翻译时崩溃**。main.lua 的
  `isTranslationManagedBook` 直接调用 `find_numbered_epub(...)`，但该函数
  是 kotranslate_reader.lua attach 内的 local 函数，在 main.lua 的作用域
  里是 nil——一旦在「翻译服务非 default」模式下选中文本翻译（触发
  Translator 覆写），就会 `attempt to call a nil value` 崩溃。修复：
  Reader.attach 里把函数挂到 `plugin.findNumberedEpub`，main.lua 改为
  安全调用。之前版本整书/逐章翻译不受影响，所以一直未被发现。
- **修复（闪退根因补全）：队列数据损坏时的启动层崩溃**。上一轮只加固了
  「翻译队列」弹窗的显示层，但队列文件含非 table 畸形项时，启动路径
  （init → loadTranslationQueue → saveTranslationQueue）和运行路径
  （startNext / findQueued / clearForBook / progress）都会在
  `item.status` / `item.book_path` 直接索引时抛错崩溃。本轮补全：
  loadQueue 加载时直接丢弃畸形项（记日志）；saveQueue / findQueued /
  clearForBook / progress / startNext 全部加 `type(item)=="table"` 防御；
  startNext 里 `_runTranslation` 入口包 pcall，启动失败标记为失败任务并
  继续下一个。现在无论队列文件多脏，插件都能正常启动、菜单能打开、
  队列能显示，不会闪退。

xp14（进度显示修复 + 队列弹窗加固）：用户反馈两个问题，均已修复。

- **修复：逐章翻译不显示进度**。xp13 的 `maybeSchedulePageTranslation`
  把静默参数写反（`silent ~= false`）：手动点击「逐章翻译」反而走了
  静默（无进度框），翻页自动续翻却弹进度框。改为 `silent == true` 后：
  手动点击 → 正常进度对话框；翻页自动续翻 → 静默。
- **修复：点击「翻译队列」闪退**。showQueue 对畸形队列项（旧版写入的
  数据、损坏的队列文件）缺少防御：`item.status`/`string.format` 直接
  处理未判类型的数据会抛错。加固：非 table / 缺 book_path 的项单独
  显示「无法识别的队列项」，数值字段全部 `or 0` 兜底；菜单 text_func
  同样加类型检查；`hasTranslationOverlay` 补 nil 判空（文件管理器下
  打开菜单也安全）。
- 队列弹窗仍无法打开时（极端数据损坏），会回退显示提示而非崩溃。

xp13（翻译入口收敛为两项）：菜单里翻译动作只剩「翻译整本书」和
「逐章翻译」两个并列入口（原「逐页翻译（文档流版）」开关移除）。

- **逐章翻译**：点击立即翻译当前章节（正常进度对话框），并自动进入
  「续翻中」状态（菜单项勾选 + 文案变为「逐章翻译（续翻中）」）；
  之后翻页到达新章节时，自动静默翻译该章（overlay 幂等合并，已翻
  段落不重复请求），整书翻完后自动停止触发。再点一次取消续翻。
- 点击触发与翻页自动触发共用同一 overlay 管线：译文写入 per-book
  overlay.json → CSS `::after` 注入文档流，与整书翻译显示完全一致。
- 引擎层新增 `span` 支持（translate_overlay 可一次翻译从当前章起
  连续 N 章，默认 1 章），为后续按需扩展保留；当前菜单只用单章。
- 静默语义收紧：仅翻页自动续翻走静默（无弹窗）；手动点击「逐章
  翻译」始终显示进度与完成提示。

xp12（整体优化 + 修复 bug）：本轮系统性审查后修复 4 处 bug、清理 1 处
遗留、1 处性能优化。

- **修复（核心）：当前章节定位失效**。Epub.resolve 原本从 xpointer 字符串
  提取 `DocFragment[N]` 索引定位章节，但 CREngine 返回的 xpointer 是
  `/body/DocFragment/body/...` 形式、**不携带 DocFragment 编号**，匹配
  几乎恒失败、回退到第 1 章——"翻译当前章节"与逐页翻译实际总翻译 spine
  第 1 章。修复：新增 `currentChapterIndex()`，用
  `isXPointerInDocument("/body/DocFragment[i]/body")` + `getPageFromXPointer`
  探测每章起始页，取「起始页 ≤ 当前页」的最后一章作为当前章节索引，把
  索引（纯数字）传给 resolve；resolve 支持纯数字 fragment；探测失败
  （API 不可用）自动回退旧行为，不会更糟。
- **修复：静默任务失败仍弹窗**。逐页翻译的章节任务是静默入队，但翻译中断
  （completed=false）和 Trapper 协程异常两个分支仍会弹「翻译已中断」/
  「翻译进程异常退出」提示，违背静默语义。两处均补 `not item.silent` 判断。
- **修复：重启后静默丢失**。translation_queue.lua 持久化字段缺 `silent`，
  KOReader 重启恢复队列后，静默章节任务会变成非静默（弹进度与完成框）。
  补进 saveQueue 的 keys。
- **清理**：main.lua onCloseDocument 删除 xp9 遗留的
  `_page_translation_data`/`_page_translation_busy`（已无任何引用）。
- **优化**：逐页翻译的 overlay complete 状态加 3 秒内存缓存，翻页不再
  每次读盘解析 overlay.json。

xp11（逐页翻译文档流化）：彻底改用整书翻译的 overlay 方案。xp9/xp10
的逐页翻译是 framebuffer 覆盖层（运行时无法把译文写进文档流，只能画
在屏幕上）；xp11 直接复用整书翻译的 overlay 管线——触发时把「当前章节」
（而不是整本书）按整书翻译同款流程处理：译文条目写入 per-book
overlay.json，由 applyAssistRuntimeStyle 转成 CSS `::after` 注入文档流。
因此译文与整书翻译完全一致：完整显示（无行数上限）、可随文档滚动、
可切换显隐、持久化（重开书仍在）、中断续翻。翻页到新章节时自动静默
触发该章翻译（串行队列 + overlay 幂等合并，已翻译段落不发重复请求）。
删除 framebuffer 绘制与「逐页译文行数」菜单。注意：CSS 选择器只能
定位到章节 DOM，所以粒度是「当前章节」而非严格意义的「当前页」——
这正是整书翻译（overlay）本身的定位机制。

xp10（逐页译文完整显示）：修正 xp9 的显示方式。整书翻译的译文是完整
段落文本（`<p class="kotranslate-translation">` 注入文档流、CSS 控制显隐），
逐页翻译此前却固定最多画 3 行小字，与"翻译本书一样的方案"不一致。
xp10 改为完整显示：译文换行后全部绘制在原文段落下方，并垫浅灰底色块
保证覆盖到下方原文时依然可读；新增菜单「逐页译文行数」子项（完整显示 /
3 / 6 / 10 行，默认完整显示）。说明：KOReader 的 CREngine 运行时无
injectHTML 类文本注入 API（官方 cre.cpp 绑定表确认），实时把译文写进
文档流不可行；整书翻译是离线改写 EPUB 文件再重开才做到的。因此逐页
翻译采用与整书翻译视觉一致的完整覆盖层方案。（xp11 起该方案被 overlay
文档流化取代，此说明保留作版本历史。）

xp9（逐页翻译 + 预取缓存）：新增独立开关「逐页翻译（预取缓存）」。
开启后按页翻译：提取当前页段落（词遍历→视觉行→段落分组），批量查缓存，
未命中部分在 Trapper 子进程内翻译（不阻塞翻页），译文画在每段原文下方
（xp9 为最多 3 行小字，xp10 起完整显示，字号/颜色复用辅助阅读设置）；
完成后自动预取后两页。译文写入与整书翻译共用的 per-book 缓存，整书
翻译的成果逐页可直接命中，反之亦然。内存页缓存保留最近 12 页，关文档/
关开关即清理。system 模式逐段请求，Edge 模式走原生批量。

xp8（引擎精简 + system 统一单条）：移除 Google provider（网络环境不可达、
无批量协议，菜单选项误导）；翻译服务仅剩两种——`system`（KOReader 内置
翻译，跟随系统引擎）与 `microsoft_free`（Microsoft Edge）。system 模式
批量统一为逐段循环（内置翻译器只有单条接口，不再做任何引擎特判路由）；
Edge 模式保留原生数组批量。默认 mode 为 system，旧配置若存 google_free
自动回落 system。

xp7（system 批量智能路由）：system 模式批量时读取 TranslatorSwitch 写入的
全局 `translator_engine` 设置——当系统翻译当前引擎是 Edge 时，绕过内置
翻译器的单条接口，直接调用 Edge 原生数组批量接口（一次请求多段）；其他
引擎（Google 等）退回逐段循环。即"跟随系统引擎 + 真批量"在 Edge 引擎下
同时成立。

xp6（系统引擎接入）：新增 `system` provider，整书/段落翻译默认直接调用
KOReader 内置翻译器（`ui/translator`，跟随用户在 KOReader → 翻译设置中的
引擎与目标语言），保留批量翻译能力（system 模式下批量 = 队列批量 +
逐段请求，因为内置翻译器只有单条接口）。同时修正默认目标语言遗留 bug
（tr → zh-Hans），并做语言码归一化（zh-Hans→zh、zh-Hant→zh-TW 对齐内置表）。
原有 Google/Edge provider 保留为可选。

xp5（菜单布局调整）：按用户要求把「启用插件」开关从顶层菜单移入子菜单
第一项。顶层只保留单个 `KoTranslate` 入口（点击进入子菜单），子菜单第一项
即「启用插件」纯 checkbox，点击直接切换启用/禁用。

xp4（菜单交互修复）：原版把「启用插件」做成了 checkbox + sub_item_table
组合，KOReader 点击时一律进入子菜单、复选框只是显示状态、切换藏在长按里，
用户无法点选启用。xp4 将开关拆为独立顶层菜单项，修复点击不可切换的问题。

xp3（排队修复）：修正打包配置 `kotranslate_configuration.lua` 中
`plugin_enabled=false` 的原版遗留 bug（新装即被禁用、翻译只排队不执行）；
入队前检查插件状态并给出明确提示；新增队列看门狗（进度文件 10 分钟无更新
自动重置卡死任务；Trapper 协程异常后强制复位 active 并继续队列）。

本版本在 KoTranslate v1.2.11 基础上，将原本深度绑定 Kindle 的实现改造为
可在 Kindle / Kobo / Android / Linux / macOS 等 KOReader 平台运行的版本。

xp2（第二轮改造）重点解决 Android 平台的两个能力缺口：词典在线安装
（不再需要外部 zstd/tar）与辅助阅读 sdcv（直接使用 Android 版 KOReader
自带的 libsdcv.so）。

## 改了哪些东西

### 1. 新增跨平台工具层 `kotranslate_tools.lua`
纯 Lua 实现的文件系统/解包工具，替代外部 shell 命令：

- `mkdir_p(path)`：递归创建目录（替代 `mkdir -p`）
- `rmtree(path)`：递归删除目录树（替代 `rm -rf`）
- `find_binary(name, extras)`：在 PATH 及候选目录中查找可执行文件并缓存
- `unzip_list / unzip_to / read_zip_entry`：基于 KOReader 内置 `ffi/archiver`
  的 ZIP 读取/解包，`safe_member` 拒绝绝对路径与 `..`，防路径穿越
- `find_file_named(name, roots, opts)`：限深、限量地搜索文件（用于旧版双语书
  与源书的跨平台定位）

### 2. 移除 Kindle 专属路径硬编码
- `kotranslate_reader.lua`：查找原书不再只搜 `/mnt/us/documents`，改为遍历
  多平台候选根：`$HOME/Documents`、`$HOME`、`/mnt/onboard`（Kobo）、
  `/mnt/ext1`、`/mnt/sd`、`/sdcard`、`/storage/emulated/0`（Android）、
  `/media`，最后仍兜底 `/mnt/us/documents`（Kindle）。
- `kotranslate_dictionaries.lua`：词典数据目录改为
  `DataStorage:getDataDir()/data/dict`（不再写死 `/mnt/us/extensions` 等），
  .ifo 扫描改用 lfs 递归，不再依赖 `find` 命令。
- `kotranslate_assist.lua`：sdcv 查找增加 PATH 探测（Linux/macOS 通常
  `apt/brew install sdcv`）。

### 3. 移除外部命令依赖（unzip / find / mkdir / rm）
`epub.lua` 全部改用 Archiver + lfs + 工具层：

- `hasAssistMarkup / hasTranslationAssistMarkup / hasCorruptAssistMarkup`：
  `io.popen("unzip ...")` → `Tools.unzip_list` + `Tools.read_zip_entry`
- `build_epub_archive`：`find . -mindepth 1` → `lfs.dir` 递归遍历
- `update_style / translate_overlay / translate_document`：mkdir/unzip/rm
  全部替换为 `Tools.mkdir_p / Tools.unzip_to / Tools.rmtree`

### 4. 配置迁移到 settings 目录
`kotranslate_state.lua`：
- 新配置路径：`DataStorage:getDataDir()/settings/kotranslate.lua`
- 启动时先读新路径；读不到则回退读取插件目录内的旧
  `kotranslate_configuration.lua`，并尽量复制迁移到新路径
- 所有保存都写入新路径（Android 上插件目录可能只读）

### 5. 词典在线安装（xp2：完全去除外部 zstd/tar）
`kotranslate_dictionaries.lua`：
- **下载**：优先 curl（Kindle / Linux / macOS 常备）；无 curl（典型
  Android）时改用 `socket.http` + KOReader 的
  `Trapper:dismissableRunInSubprocess` 走系统 HTTPS 栈后台下载。
- **解包**：统一用 KOReader 内置 `ffi/archiver`（libarchive）直接解
  `.tar.zst`——KOReader 官方 libarchive 自带 zstd 过滤器，无需外部
  zstd/tar 命令。状态机：`downloading → downloaded → extracting → done`，
  解包完成后自动清理临时文件并标记已安装。
- 镜像源按序尝试：ghproxy.net → gh-proxy.com → GitHub 直连（各 3 次重试）。
- 全部外部命令参数经 `shell_quote` 转义。

### 6. 辅助阅读 sdcv（xp2：Android 用内置 libsdcv.so）
`kotranslate_assist.lua`：
- `find_sdcv()` 优先返回 Android 版 KOReader 自带的
  `android.nativeLibraryDir/libsdcv.so`（无需安装任何东西），其次才是
  数据目录下的 sdcv 与 PATH 探测。
- 执行 libsdcv.so 前设置 `LD_LIBRARY_PATH = android.nativeLibraryDir`
  （与 KOReader 官方 ReaderDictionary 完全相同的做法），运行后还原。
- 因此 Android 上日文假名/罗马音、英文 IPA 等辅助读音开箱即用。

## 各平台安装

与普通 KOReader 插件相同：把解压后的 `kotranslate.koplugin` 目录放入
KOReader 的 `plugins/` 目录，重启 KOReader，在阅读菜单中出现
「翻译/KoTranslate」菜单项即安装成功。

| 平台 | 备注 |
| --- | --- |
| Kindle | 与旧版完全一致，路径、命令均兼容 |
| Kobo | 自动使用 `/mnt/onboard`；数据目录随 KOReader |
| Android | 配置写入 settings 目录；翻译 API 直接走网络 |
| Linux / macOS | 自动使用 `$HOME/Documents` |

## 残余限制

- 整书翻译（overlay 模式）的 CSS 选择器针对 CREngine 生成，其他阅读引擎
  不支持覆盖层显示；这是上游设计，非本版改动。
- 已知上游遗留问题：`main.lua` 默认目标语言已由 xp6 修正（tr → zh-Hans）；
  `INLINE_EPUB.md` 描述的功能（MyMemory/内联双语）与当前实现不符。

## 1.2.11-xp40 — 进度条与取消入口合一
- 进度条交互：点按进度条本体 → 弹出取消操作窗口（[返回] [取消翻译]）；点按外部 → 收起进度条（任务继续，原行为）。
- 队列菜单：翻译中（active）任务点按 → 重新弹出进度条（再点本体可取消）；排队中/失败任务点按 → 保持取消确认框；进度条不可用时自动回退确认框。
- reopenTranslationProgress 支持"进度条仍显示但被菜单遮挡"场景（不再重复弹出）。
- State.attach 暴露 cancelTranslation；进度条操作窗口复用队列取消逻辑（写 .cancel 标志，批次边界停止）。
- 测试：新增 queueui_test（队列行行为 + 重开 + 回退 + 空队列），loadtest 增加 attach 断言；8 套测试全绿。

## 1.2.11-xp41 — 翻译队列改为原生子菜单
- 队列不再弹出独立窗口：主菜单「翻译队列」项用 sub_item_table_func 动态展开原生子菜单（与「翻译服务」「语言」一致）。
- 翻译中任务：点按 → 关闭菜单并重新弹出进度条（再点本体可取消）；进度条不可用时回退取消确认框。
- 排队中/失败任务：点按 → 展开原生子菜单 [取消翻译]（无弹窗），确认后移除并提示。
- 队列为空时菜单项置灰并显示「翻译队列（空）」。
- 删除 State.showQueue 独立弹窗实现与残留 require（Menu/Screen）；新增 queueStats 统计方法。

## 1.2.11-xp42 — 清除译文与"本书已翻译"误报修复
- 逐章模式下"翻译本书"不再用 overlay.complete 判断"已翻译完成"：章节翻译从不写 complete，该标记只来自更早的整书翻译（可能语言已换/缓存已清），据此拒绝会让用户无法补翻/重翻当前章。现在逐章模式下"翻译本书"始终翻译当前章并武装跟随模式。
- "清除本书译文"改为跨语言彻底清除：overlay.json 带 book_path/target_lang 元数据（v1.2.11 起已有），清除时除当前语言目录外，遍历 books 根目录删除所有属于同一本书的语言目录——修复"翻译完成后改过目标语言 → 旧语言 overlay 残留 → 清除后仍提示已翻译/残留旧译文"。
- 清除译文后重置逐章跟随状态（follow_active/fragment/overlay_state/chapter_index），防止清除后翻页立即自动重翻。
- 删除不再使用的 Overlay.isComplete。
- 新增 tests/clear_test.lua 回归：整书残留不阻挡逐章翻译 / 清除后重翻 / 多语言残留清除 / 其他书目录不受影响。

## 1.2.11-xp43 — 全面审查清理
- 进度条改为原位更新：不再每 0.5s 重建整棵 UI 树（ProgressbarDialog:init()），直接更新 dialog[1][1][1]/[1][1][2] 的 TextWidget 文本 + reportProgress，刷新更顺滑。
- 删除 4 处 MYMEMORY WARNING 字符串过滤死代码（system/microsoft_free 引擎不会返回该格式，MyMemory 引擎早已移除）。
- 删除无读取方的 _auto_open_checked_path 死字段。
- 菜单「中文翻译」更名「显示译文」（语义即译文可见性开关，勾选=显示）。
- 打包排除 dualtranslate_configuration.lua / _sample.lua（旧版迁移源文件，随包安装会在启动时被 loadConfig 尝试改名，属污染）。

## 1.2.11-xp44 — 移除选中文本翻译覆盖
- 删除对 KOReader 内置 Translator.showTranslation 的覆盖（syncTranslateOverride）及 isTranslationManagedBook 判定：选中文本翻译完全交还 KOReader 原生功能（原生引擎/原生弹窗/原生存笔记）。
- 删除随之失去调用方的 translateText 与 TranslationUI.showTranslation（TextViewer 弹窗），dualtranslate_ui.lua 精简为 Notification 工具。
- 删除 Cache 共享表 lookup/store 两个死函数（translations 表结构保留以兼容旧库与 clear()）。
- 同步更新 callcheck 白名单、cache_test、loadtest stub。

## 1.2.11-xp45 — 修复"翻页直接显示翻完了"
- 根因：逐章跟随模式下，进入已翻译过的章节时，调度器只检查 overlay.complete（章节翻译从不写 complete），照常重新排队该章；翻译 job 打开 overlay 后所有段落全部命中旧缓存，0 次新请求、进度条瞬间 100%，表现为"点翻页就直接显示翻完了"。
- 修复：overlay.json 持久化 chapters 覆盖标记（本次及历次已处理的 spine 章序号，断点续传会合并历史）；maybeSchedulePageTranslation 在调度前检查当前章是否已被覆盖，已覆盖则跳过，不再触发虚假翻译。旧版 overlay 无该字段时按原行为处理（兼容）。
- 加固：currentChapterIndex 探测忽略无版面的空 spine 项（page<=0 不计入当前章，避免把空章当当前章翻译成瞬间 100%）。
- 测试：epub_test 新增整书/章节模式 chapters 覆盖标记断言。

## 1.2.11-xp46 — 修复"翻页提示已到书末（EndOfBook）但实际在书中间"
- 根因：每次翻译完成/样式变更都会调 document:setStyleSheet 触发全量重排，但重排后 reader 的分页状态（滚动模式的 page_states、翻页模式的 current_page）不会自动重建，残留旧布局页码；翻页时 getNextPage(旧页码) 可能返回 0，KOReader 误触发 EndOfBook 弹窗（"已到书末"），而书实际还在中间。
- 修复：refreshDocumentStyles 在 setStyleSheet 成功后 nextTick 同步分页状态——PageUpdate 刷新当前页 → ReaderView:recalculate → InitScrollPageStates 重建滚动页状态（KOReader 官方在旋转/改尺寸后使用的同一机制）。非滚动模式 InitScrollPageStates 为 no-op，无副作用。
- 测试：loadtest / clear_test 补 ui/event stub。

## 1.2.11-xp47 — 全面审查优化
- buildCss 增加 mtime+选项签名缓存（大书逐章翻译每次完成后 refreshDocumentStyles 不再重复解析整个 overlay.json；worker 原子替换文件保证 mtime 即内容指纹，缓存上限 16 条防膨胀）。
- 章节探测（currentChapterIndex）：空 spine 项（存在但无版面，page<=0）改为"跳过继续扫描"而非终止扫描——修复"空章之后的所有章节永远定位不到、翻译落到错误章节"的隐患；探测上限 512→4096（超长书不再顺向翻页定位到错误章）。
- 译文字号从 InputDialog 弹窗改为原生 radio 子菜单（与语言/字体菜单同构），保留"自定义…"自由输入入口。
- 测试：fulltest 补 lfs stub 与 buildCss 缓存行为断言（命中/选项变化重建）。

## 1.2.11-xp48 — 字号改用 KOReader 原生 SpinWidget 增减控件
- "译文字号"从 radio 子菜单改为原生 SpinWidget（- / + 增减 + 点按数字直接输入 8–40），与 KOReader 其余数值设置一致。
- 删除 buildInlineFontMenu / showInlineFontDialog 及其测试白名单条目；测试补 spinwidget stub。

## 1.2.11-xp49 — 默认引擎改为 Microsoft Edge 免费翻译
- 默认翻译引擎从 system（KOReader 内置）改为 microsoft_free（Edge 免费批量），新安装/未显式选择过引擎的用户直接使用微软翻译。
- README 引擎对照表与测试 mock 同步更新。
