# mcp-kit — дизайн второй итерации: MCPKitServer

Дата: 2026-11-09

## Цель

Helper приложения поднимает MCP-сервер через один пакет. Разработчик описывает тулы декларативно, а kit берёт на себя JSON-схемы, разбор аргументов, ошибки, прогресс и запуск по stdio. Swift-sdk отдельно подключать не нужно.

## Решения

| Вопрос | Решение |
|---|---|
| Основа | Официальный [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) `from: "0.12.1"`, без форка. Он поддерживает протокол до 2025-11-25, этого хватает для stdio с Claude Code и Codex |
| Слой | Свой тонкий декларативный слой. Сырой swift-sdk остаётся доступен через реэкспорт `MCP` |
| Возможности | Тулы, `instructions` сервера, уведомления о прогрессе. Resources и prompts пишутся на сыром swift-sdk |
| JSON-схема | Строится декодером-регистратором из `Decodable`-типа входа, без новых зависимостей |
| Плагины | Не делаем. MCP и скилл из первой итерации покрывают задачу |
| Распространение | Приватный репозиторий на Gitea, semver-теги. Публикация позже |

## Пакет

- Продукт `MCPKit` остаётся без зависимостей и подключается к таргету приложения.
- Новый продукт `MCPKitServer` зависит от `MCP` и подключается к таргету helper. Он делает `@_exported import MCP`, поэтому helper обходится одним `import MCPKitServer`.
- Executable-таргет `ExampleHelper` (не продукт) служит примером и нужен для живого smoke-теста.

## API

```swift
import MCPKitServer

struct RenderArgs: ToolInput {
    let frame: Int
    let format: Format?
    static let descriptions = ["frame": "Frame number", "format": "Output format"]
}

enum Format: String, ToolInputEnum { case png, jpeg }   // ToolInputEnum = CaseIterable + String raw value

@main struct Helper {
    static func main() async throws {
        try await MCPServer(name: "filmcraft", version: "1.0", instructions: "Edits FilmCraft projects.") {
            Tool("render_frame", "Render one frame", input: RenderArgs.self) { args, context in
                await context.progress(0.5, total: 1, message: "Rendering")
                return .text("Rendered \(args.frame)")
            }
            Tool("ping", "Health check") { _ in .text("pong") }
        }.runStdio()
    }
}
```

- `ToolInput: Decodable, Sendable` по умолчанию возвращает пустой `descriptions`.
- `Tool` бывает в трёх формах: без входа, со входом, со входом и `ToolContext`.
- `ToolOutput` предоставляет `.text(String)`, `.json(some Encodable)`, `.image(Data, mimeType:)` и `.content([MCP.Tool.Content])` для всего остального.
- `ToolContext.progress(_:total:message:)` отправляет `notifications/progress`, только если клиент передал `progressToken` в `_meta`. Без токена вызов ничего не делает.
- `MCPServer.runStdio()` запускает `StdioTransport` и ждёт завершения. Логи пишутся только в stderr, в stdout не выводится ничего, кроме сообщений протокола.

## Схема из `Decodable`

При регистрации тула kit один раз декодирует тип входа специальным `SchemaDecoder` и записывает запрошенные ключи и типы.

| Swift | JSON Schema |
|---|---|
| `String`, `URL` | `string` (для `URL` ещё `format: uri`) |
| `Int`, `Int8…64`, `UInt…` | `integer` |
| `Double`, `Float` | `number` |
| `Bool` | `boolean` |
| `[T]` | `array` с `items` |
| `[String: T]` | `object` с `additionalProperties` |
| вложенный `Decodable` | `object` с `properties` и `required` |
| `ToolInputEnum` | `string` с `enum: [...]` |
| ключ через `decodeIfPresent` | не попадает в `required` |

Схема корня всегда `object`. Если тип описать нельзя (неподдерживаемый тип или вход не объект), `MCPServer` бросает `MCPKitServerError.unsupportedInput(tool:reason:)` до старта сервера.

## Обработка вызова

1. Если тул с таким именем не найден, kit возвращает протокольную ошибку `invalidParams`.
2. Аргументы декодируются в `Input`. Если декодирование не удалось, kit возвращает результат с `isError: true` и понятным текстом: какое поле и что не так.
3. Если обработчик бросил ошибку, kit возвращает результат с `isError: true` и `localizedDescription`. По соглашению MCP так модель видит ошибку тула и может исправить вызов.
4. Если всё прошло успешно, kit возвращает `ToolOutput`, переведённый в `content`.

## Тестирование

- Сервер и клиент swift-sdk соединяются через транспорт в памяти, без процессов.
- Тесты схем: каждый тип из таблицы выше, optional, вложенные структуры, enum, пустой вход, неподдерживаемый тип.
- Тесты вызова: успешный вызов, неверные аргументы, ошибка обработчика, неизвестный тул, прогресс с токеном и без него.
- Живой smoke-тест (`MCPKIT_LIVE=1`): `MCPKit` подключает собранный `ExampleHelper` к Claude Code и Codex, `claude mcp get` показывает, что сервер подключён, после чего запись удаляется.

## README

Разделы: какой продукт подключать к какому таргету; как положить helper в `Contents/Helpers` через Copy Files и подписать с hardened runtime; где лежат скиллы; пример helper.
