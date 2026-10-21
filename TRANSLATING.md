# Translating Macterm

Thank you for your help with the translation of Macterm. This guide tells you where the text is, how to add a language and which words to use.

## Where the text is

All the text of the app is in three String Catalogs:

- `Macterm/Localizable.xcstrings` has the text of the app: menus, the command palette, Settings, the sidebar, alerts and notifications.
- `Macterm/InfoPlist.xcstrings` has the text of the permission prompts that macOS shows when a program in a pane asks for a permission.
- `Macterm/ServicesMenu.xcstrings` has the item of Macterm in **Finder → Services**. It has one entry for the release app and one for the Debug app.

A String Catalog is a JSON file. Each entry is one English string. The entry holds one translation for each language. You can edit the file in Xcode, which shows a table, or in a text editor.

Most entries use the English text as their key. Some entries have a key such as `tab.status.done` and an English value ("Done"). These entries are words with more than one meaning in English. Translate the English value, and read the comment to know which meaning it is.

These items are always in English. Do not translate them:

- The output of the CLI (`macterm`) and of the agent skills. Scripts and coding agents read it.
- Log lines.
- Text that comes from Ghostty itself, such as the messages in a pane.
- Text that you write yourself: project names, tab names, extensions and palette files.

## Choose the language of Macterm

Macterm uses the language of macOS. To use a different language for Macterm only, select it in **Settings → General → Language**. Then quit Macterm and start it again. **System** uses the language of macOS again.

**System Settings → General → Language & Region → Applications** sets the same choice.

## Add a language

1. Open `Macterm/Localizable.xcstrings` in Xcode. Click **+** at the bottom of the language list and select the language.
2. Translate each entry. Xcode marks an entry that you translated as done.
3. Do the same in `Macterm/InfoPlist.xcstrings` and `Macterm/ServicesMenu.xcstrings`.
4. Add a word table for the language to this file (see [Korean](#korean)).
5. Build and run the app in the language (see above) and look at each screen. The new language shows in **Settings → General → Language** automatically.

Without Xcode, add a `"<language>" : { "stringUnit" : { "state" : "translated", "value" : "…" } }` object under `"localizations"` of each entry. Use the language codes of Apple, such as `ko`, `ja`, `zh-Hans` and `de`.

A test (`LocalizationTests`) makes sure that every entry has a translation in each language of the catalog, and that each translation keeps the placeholders of the English string.

## Placeholders

`%@` is a text value, `%lld` is a number. Keep each placeholder in the translation. When a language needs the values in a different order, number them: `%1$@`, `%2$@`.

## Add or change English text

The compiler finds the English text in the Swift code. A SwiftUI literal such as `Text("New Tab")` is localizable as it is. A `String` that the app shows must use `String(localized: "New Tab")` where the code defines it. Write a whole sentence in one string. Do not join two localized strings into one sentence.

After you add or change English text, update the catalog:

```bash
mise run strings
```

This builds the app and merges the strings of the code into `Macterm/Localizable.xcstrings`. It also removes the entries that the code does not use now. CI runs `mise run strings --check` and fails when the catalog is not in sync. A new string also needs a translation in each language, or `LocalizationTests` fails.

## Korean

Korean text follows the terms of macOS in Korean, so that the menus of Macterm agree with the menus that macOS adds (**Edit**, **Window**, **Help**).

- Use the polite formal style (합니다체) in descriptions and messages: "탭을 닫습니다."
- Write menu items, buttons and titles as noun phrases: "새로운 탭", "탭 닫기".
- Write a question in an alert as "…하시겠습니까?".
- Keep product names, file names, commands, config keys and key names in English: Macterm, Ghostty, zmx, SSH, `config.ghostty`.
- Keep the ellipsis "…" of the English text.

| English | Korean | Note |
|---|---|---|
| project | 프로젝트 | |
| tab | 탭 | |
| pane | 페인 | The word of tmux users. 창 is the word for a window in many apps, so it is not clear. |
| split | 분할 | "Split Right" is "오른쪽으로 분할". |
| window | 윈도우 | As in the **Window** menu of macOS. |
| session | 세션 | |
| pinned tab | 고정된 탭 | Pin is "고정", unpin is "고정 해제". |
| unload | 언로드 | Not 종료: the row stays. |
| layout | 레이아웃 | |
| remote project | 원격 프로젝트 | |
| quick terminal | 빠른 터미널 | |
| desktop widget | 데스크탑 위젯 | |
| command palette | 명령 팔레트 | |
| palette | 팔레트 | |
| screen (of the palette) | 화면 | |
| extension | 확장 프로그램 | |
| keybind | 단축키 | |
| keymap | 키맵 | |
| sidebar | 사이드바 | |
| settings | 설정 | |
| Appearance (the Settings pane) | 스타일 | |
| password manager | 암호 관리자 | As in the Passwords app of macOS (암호). |
| password | 암호 | |
| autofill | 자동 완성 | |
| copy mode | 복사 모드 | |
| select mode | 선택 모드 | |
| read-only mode | 읽기 전용 모드 | |
| zoom (a pane) | 확대 | |
| focus | 포커스 | |
| scrollback | 스크롤백 | |
| shell | 셸 | |
| prompt (of a shell) | 프롬프트 | |
| config file | 설정 파일 | "Ghostty config" is "Ghostty 설정". |
| reload | 다시 불러오기 | |
| toggle | 전환 | "Toggle Sidebar" is "사이드바 전환". |
| agent | 에이전트 | |
| Shortcuts (the app) | 단축어 | The name of the app in Korean. |

## Simplified Chinese

Simplified Chinese (`zh-Hans`) text follows the terms of macOS in Simplified Chinese, so that the menus of Macterm agree with the menus that macOS adds (**编辑**, **窗口**, **帮助**).

- Write menu items, buttons and titles as short phrases: "新建标签页", "关闭标签页".
- Write descriptions and messages as plain, complete sentences: "关闭标签页并结束其会话。"
- Write a question in an alert as "要……吗？": "要退出 Macterm 吗？"
- Use full-width punctuation in Chinese text: "，", "。", "：", "？", "（）". Keep "…" for an ellipsis.
- Put a space between Chinese text and a Latin word or a number: "在 Ghostty 设置中", "%lld 个标签页".
- Keep product names, file names, commands, config keys and key names in English: Macterm, Ghostty, zmx, SSH, `config.ghostty`.

| English | Simplified Chinese | Note |
|---|---|---|
| project | 项目 | |
| tab | 标签页 | |
| pane | 窗格 | |
| split | 拆分 | "Split Right" is "向右拆分". |
| window | 窗口 | |
| session | 会话 | |
| pinned tab | 固定的标签页 | Pin is "固定", unpin is "取消固定". |
| unload | 停止 | Not 卸载: that is "uninstall". The row stays. |
| layout | 布局 | |
| remote project | 远程项目 | |
| quick terminal | 快速终端 | |
| desktop widget | 桌面小组件 | |
| command palette | 命令面板 | |
| palette | 面板 | |
| screen (of the palette) | 屏幕 | |
| extension | 扩展 | |
| keybind | 快捷键 | |
| keymap | 键位映射 | |
| app | App | As in macOS. 应用 is "apply". |
| item | 项 | Not 项目: that is "project". |
| rename | 重新命名 | |
| capture | 捕捉 | |
| sidebar | 边栏 | |
| settings | 设置 | |
| Appearance (the Settings pane) | 外观 | |
| password manager | 密码管理器 | |
| password | 密码 | |
| autofill | 自动填充 | |
| copy (an action) | 拷贝 | As in the **编辑** menu of macOS. |
| save | 存储 | As in the **文件** menu of macOS. |
| copy mode | 拷贝模式 | |
| select mode | 选择模式 | |
| read-only mode | 只读模式 | |
| zoom (a pane) | 放大 | |
| focus | 聚焦 | |
| scrollback | 回滚缓冲区 | |
| shell | shell | |
| prompt (of a shell) | 提示符 | |
| config file | 配置文件 | "Ghostty config" is "Ghostty 配置". |
| reload | 重新载入 | |
| toggle | 切换 | "Toggle Sidebar" is "切换边栏". |
| agent | 智能体 | |
| Shortcuts (the app) | 快捷指令 | The name of the app in Simplified Chinese. |
