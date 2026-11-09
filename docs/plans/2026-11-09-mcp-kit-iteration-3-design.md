# mcp-kit — дизайн третьей итерации: строгий MCPKitServer

Дата: 2026-11-09

## Причина

Перенос Undersong на `MCPKitServer` 0.2.0 остановился на проверке совместимости. Отчёт лежит в `UndersongProject/app-mcp-kit/.build/mcp-kit-compatibility/REPORT.md`. Чего не хватает:

1. `structuredContent` в результате тула.
2. Аннотаций тулов (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `title`).
3. Строгого ввода. `Codable` молча отбрасывает неизвестные ключи и явные `null`, а в схеме нет `additionalProperties: false`, диапазонов, длин и `maxItems`.

Всё это нужно любому приложению, поэтому добавляется в kit, а не в Undersong.

## Решения

| Вопрос | Решение |
|---|---|
| Аннотации | Необязательный параметр `annotations:` у всех инициализаторов `Tool`, тип `MCP.Tool.Annotations` из swift-sdk |
| Структурный результат | `ToolOutput.structured(_ value: some Encodable, text: String? = nil)`: `structuredContent` берётся из `value`, в `content` кладётся `text` или JSON того же значения |
| Ограничения | `ToolInput.constraints: [String: [SchemaConstraint]]`, по умолчанию пусто. `SchemaConstraint`: `.range(ClosedRange<Double>)`, `.length(ClosedRange<Int>)`, `.items(ClosedRange<Int>)`. Ключ, который не совпадает ни с одним полем, вызывает ошибку до старта, как и в `descriptions` |
| Схема | Каждый объект получает `additionalProperties: false` (кроме `[String: T]`). Ограничения выводятся как `minimum`/`maximum`, `minLength`/`maxLength`, `minItems`/`maxItems` |
| Проверка | Перед `Codable` kit проверяет сырые аргументы по той самой схеме, которую видит агент: типы, `required`, неизвестные ключи, `null` (запрещён везде: опциональное поле нужно просто не передавать), `enum`, все ограничения. Ошибка возвращается как `isError: true` с путём к полю. Схема — единый источник истины |
| Неизвестный тул | Остаётся протокольная ошибка `invalidParams`, как требует спецификация MCP |
| Версия | `0.3.0`. Публичный API 0.2.0 не ломается |

## Тестирование

- Каждое ограничение есть в схеме и проверяется на границах: внутри, на краю, снаружи.
- Неизвестный ключ на корне, во вложенном объекте и в элементе массива; явный `null`; неверный тип; значение вне `enum`.
- `[String: T]` по-прежнему принимает произвольные ключи.
- `structuredContent` и аннотации доходят до настоящего `Client` через `InMemoryTransport`.
- Ошибочный ключ в `constraints` вызывает ошибку до старта.
