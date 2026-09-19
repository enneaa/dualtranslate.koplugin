# DualTranslate 测试套件

纯 Lua + stub 环境，无需 KOReader。在 kotranslate_xplatform/ 目录下运行：

    lua tests/loadtest.lua      # 加载 + init + 设置读写 + 菜单构建 + 全项渲染
    lua tests/fulltest.lua      # 文本切分 / Overlay CSS / Tools hash / Languages / 队列 / Providers
    lua tests/epub_test.lua     # EPUB resolve / 段落收集 / translate_overlay 完整流程
    lua tests/state2_test.lua   # loadConfig 迁移 / loadQueue 边界
    lua tests/cache_test.lua    # SQLite cache（mock）
    lua tests/langmenu_test.lua # 语言子菜单闭包
    lua tests/callcheck.lua     # 方法调用完整性

注意：
- 测试读写 /tmp 下临时目录（/tmp/dt_data、/tmp/dt_state_test、/tmp/dualtranslate_epub_test 等）。
- G_reader_settings 桩必须用冒号调用签名 (self, key[, value])。
- 新增模块级函数后，把函数名加入 callcheck.lua 的 attached 白名单。
- 新增模块后若 /tmp 被清，测试脚本可从本目录复制回去（或直接在此运行）。
