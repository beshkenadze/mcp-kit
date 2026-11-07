# mcp-kit — дизайн первой итерации

Дата: 2026-11-07

## Цель

Swift-пакет, который macOS-приложение встраивает, чтобы подключать свой MCP-сервер и скиллы к агентам: Claude Code, Claude Desktop и Codex. Приложение описывает себя один раз, а kit пишет конфиги агентов в user scope, показывает статус и снимает интеграцию по запросу.

Позже kit понадобится приложениям на Tauri 2 и GPUI (Rust). Поэтому знания о форматах агентов хранятся отдельно от кода, в декларативном реестре.

## Решения

| Вопрос | Решение |
|---|---|
| Форма | SDK для встраивания. Сейчас SwiftUI, позже Tauri 2 и GPUI |
| Модель сервера | stdio-helper внутри бандла приложения. Приложению не нужно быть запущенным |
| Транспорт | stdio. Его принимают все три агента, включая Claude Desktop. HTTP не нужен |
| Агенты | Claude Code, Claude Desktop, Codex |
| Ядро | Swift-движок и общий реестр `spec/agents.json` с golden-фикстурами. Rust-движок появится позже и прочитает тот же реестр |
| Запись конфигов | Только файлы. CLI агентов используются лишь в живом smoke-тесте |
| UI | Нет. Kit отдаёт статусы и методы, интерфейс рисует приложение |
| Песочница | Первая итерация работает без App Sandbox. Запись идёт через протокол `ConfigWriter`, чтобы позже подключить вариант для Mac App Store |

## Не входит в первую итерацию

- Реэкспорт [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk), чтобы приложение объявляло MCP-тулы через один пакет.
- Установка плагинов (`claude plugin`, `codex plugin`). Kit будет собирать их в рантайме из той же декларации: путь к helper известен только на машине пользователя.
- Gemini CLI, OpenCode, Cursor. Каждый добавляется записью в реестре и адаптером.
- Песочница (Mac App Store).
- Готовые SwiftUI-вьюхи.
- Мост между helper и запущенным приложением. Его пишет само приложение.

## Архитектура

### Структура репозитория

```
spec/agents.json          реестр агентов, единый источник истины для Swift и Rust
spec/fixtures/<agent>/…   golden-кейсы before/after
Sources/MCPKit/           движок
Tests/MCPKitTests/
```

Пакет на SwiftPM: Swift 6 со строгой конкурентностью, macOS 14+, без сторонних зависимостей. Продукт один — `MCPKit`.

### Публичный API

```swift
let integration = MCPIntegration(
    name: "filmcraft",                         // имя сервера в конфигах
    displayName: "FilmCraft",
    helper: .bundled("Contents/Helpers/filmcraft-cli"),
    arguments: ["mcp"],
    skills: [.bundled("Skills/filmcraft")]     // папка с SKILL.md
)
let kit = MCPKit(integration)

await kit.status()               // [AgentID: AgentStatus]
try await kit.connect(.codex)
try await kit.disconnect(.claudeCode)
try await kit.disconnectAll()
try await kit.reconcile()        // вызывать при запуске приложения
```

`AgentStatus`: `agentNotFound`, `disconnected`, `connected`, `outdated`, `conflict`, `unavailable(reason)`.

### Стабильный путь к helper

Kit создаёт симлинк `~/Library/Application Support/<bundle-id>/mcp-kit/bin/<name>` → helper в бандле и пишет в конфиги путь к симлинку. Если приложение переместили, `reconcile()` перенаправляет симлинк, а конфиги агентов остаются прежними. Симлинк служит и маркером владения: запись принадлежит kit, если её `command` указывает на этот путь.

Helper определяет своё расположение через `realpath`, а не через `argv[0]`.

### Реестр агентов

```json
"codex": {
  "displayName": "Codex",
  "detect": { "paths": ["~/.codex"] },
  "config": { "path": "~/.codex/config.toml", "format": "toml", "serversKey": "mcp_servers" },
  "skillsDir": "~/.agents/skills",
  "restartHint": null
}
```

| | Claude Code | Claude Desktop | Codex |
|---|---|---|---|
| Обнаружение | `~/.claude.json` или `~/.claude/` | bundle id `com.anthropic.claudefordesktop` | `~/.codex/` |
| Конфиг | `~/.claude.json` → `mcpServers` | `~/Library/Application Support/Claude/claude_desktop_config.json` → `mcpServers` | `~/.codex/config.toml` → `[mcp_servers.<name>]` |
| Запись | `{type: "stdio", command, args, env}` | `{command, args, env}` | таблица TOML и подтаблица `env` |
| Скиллы | `~/.claude/skills` | нет, скиллы Desktop облачные | `~/.agents/skills` |
| После изменения | — | подсказка о перезапуске | — |

Пути к скиллам и форматы записей сверить с актуальной документацией при заполнении реестра.

### Компоненты

- **`ConfigReader`** читает конфиг и вычисляет статус. Для TOML разбирает только таблицу `[mcp_servers.<name>]`: поля `command`, `args` и `env`.
- **`ConfigWriter`** (протокол) и **`FileWriter`** (реализация):
  1. читает файл прямо перед записью;
  2. меняет один ключ JSON или заменяет одну таблицу TOML вместе с подтаблицами, остальной текст не трогает;
  3. копирует исходный файл в `<file>.mcp-kit.bak`;
  4. пишет во временный файл в той же папке, сохраняет права исходного (у `~/.claude.json` это `0600`) и делает rename;
  5. перечитывает файл и проверяет запись. Если записи нет, повторяет попытку один раз.
- **`SkillInstaller`** копирует папку скилла и кладёт в неё маркер `.mcp-kit.json` с bundle id и версией приложения. Если два агента читают одну папку, копирует скилл туда один раз.

Почему без CLI: Claude Code сам пишет `~/.claude.json` через временный файл и rename, без lock-файла. Команда `claude mcp add` выполняет то же чтение, изменение и запись, поэтому от гонки не защищает. Прямая запись избавляет от поиска бинарей через урезанный `PATH` GUI-приложения и от второго пути записи.

## Потоки данных

`MCPKit` — это `actor`: операции внутри приложения выполняются последовательно.

**`status()`** для каждого агента из реестра:
1. агент не обнаружен → `agentNotFound`;
2. записи с нашим `name` нет → `disconnected`;
3. `command` указывает не на наш симлинк → `conflict`;
4. аргументы или env расходятся с декларацией либо версия в маркере скилла старше версии приложения → `outdated`;
5. иначе → `connected`.

**`connect(agent, force: false)`:**
1. создаёт или перенаправляет симлинк на helper;
2. при `conflict` без `force` бросает `MCPKitError.conflict`;
3. собирает запись по шаблону агента;
4. записывает её через `ConfigWriter`;
5. копирует скиллы в `skillsDir`;
6. возвращает `ConnectResult` с `restartHint`.

**`disconnect(agent)`:**
1. удаляет запись, если она принадлежит kit;
2. удаляет папки скиллов с нашим маркером, если их не использует другой подключённый агент;
3. удаляет симлинк, когда не осталось подключённых агентов.

**`reconcile()`:**
1. перенаправляет симлинк на helper в текущем бандле;
2. выполняет `connect` для агентов в статусе `outdated`;
3. агентов в статусе `disconnected` не подключает.

Kit не следит за файлами, не перезапускает агентов и ничего не подключает без вызова со стороны приложения.

## Ошибки

```swift
enum MCPKitError: Error {
    case helperMissing(URL)
    case conflict(AgentID, existingCommand: String)
    case unreadableConfig(AgentID, URL, underlying: Error)
    case unsupportedLayout(AgentID, URL)
    case skillConflict(URL)
    case writeFailed(AgentID, URL, underlying: Error)
    case verificationFailed(AgentID)
}
```

- Файл, который kit не смог разобрать, он не перезаписывает. `status()` возвращает `unavailable`, `connect` бросает `unreadableConfig`.
- Если наша запись в TOML оформлена inline-таблицей или dotted keys, kit бросает `unsupportedLayout`.
- Конфиг для необнаруженного агента kit не создаёт. Если агент обнаружен, а файла нет, kit создаёт файл только с нашей записью.
- Отката нет. Операции идемпотентны: следующий `connect` или `reconcile()` доводит работу до конца.
- Если приложение удалили, симлинк повисает. README рекомендует вызывать `disconnectAll()` из сценария удаления.
- Логи пишутся в `os.Logger` с subsystem `mcp-kit`.

## Тестирование

- **Изоляция.** `MCPKit(integration, environment: .init(home:, bundleURL:))`. Тесты работают во временном HOME, на Swift Testing (`swift test`).
- **Golden-фикстуры** лежат в `spec/fixtures/<agent>/<case>/{before, after}`. Кейсы: файла нет, файл пустой, есть чужие серверы, наша запись устарела, чужой конфликт, TOML с комментариями, битый файл. TOML сравнивается побайтно, JSON — семантически. Тот же набор потом проверит Rust-движок.
- **Юнит-тесты** покрывают статусы, `reconcile()` после переноса бандла, удаление общего скилла только после отключения последнего агента и повтор после перезаписи файла между чтением и записью.
- **Живой smoke-тест** (`MCPKIT_LIVE=1`) подключает тестовый helper к реальным конфигам, проверяет запись через `claude mcp get` и `codex mcp get` и отключает его.
