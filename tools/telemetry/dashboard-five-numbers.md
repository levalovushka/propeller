# Дашборд: пять чисел

Запросы для инсайтов дашборда «Users» в TelemetryDeck. Каждый прогнан живьём
через MCP-коннектор 2026-08-26 и отдал число, которое стоит рядом — если инсайт
показал другое, сначала подозревай период и фильтр Live/Test, а не запрос.

Правила чтения — `STATE.md` §12. Здесь только запросы и то, чем они врут.

**Как вставлять.** Инсайт создаётся в дашборде, запрос вставляется в редактор
запроса. Коннектор подставляет `dataSource`, `appID` и `baseFilters` сам — если
редактор их требует, добавь `"baseFilters": "thisApp"` и appID приложения
(`FD2E1040-C134-4F44-BCAC-76441E1662D7`).

**Общее для всех.** Окно — последние 30 дней. Фильтр `isTestMode = false`
обязателен везде: DEBUG-сборки шлют в Test, и без фильтра числа смешиваются.
Считаются **машины**, а не люди: переустановка и второй Mac дают +1. Внутри
всех чисел сидит девмашина (7 086 событий, 14 разных дат первой сессии) —
на долях это не сказывается, на счётчиках сказывается.

---

## 1. Кто дошёл до записи

Машин открывало приложение, машин записало встречу, и доля вторых в первых.

**2026-08-26: 76 открывали, 64 записали, 84 %.**

```json
{
  "queryType": "timeseries",
  "granularity": "all",
  "aggregations": [
    {"type": "filtered",
     "filter": {"type": "selector", "dimension": "type", "value": "Propeller.Recording.finished"},
     "aggregator": {"type": "thetaSketch", "fieldName": "clientUser", "name": "machines_recorded"}},
    {"type": "filtered",
     "filter": {"type": "selector", "dimension": "type", "value": "Propeller.App.opened"},
     "aggregator": {"type": "thetaSketch", "fieldName": "clientUser", "name": "machines_opened"}}
  ],
  "postAggregations": [
    {"type": "arithmetic", "name": "share_recording", "fn": "/",
     "fields": [
       {"type": "finalizingFieldAccess", "fieldName": "machines_recorded"},
       {"type": "finalizingFieldAccess", "fieldName": "machines_opened"}
     ]}
  ],
  "filter": {"type": "selector", "dimension": "isTestMode", "value": "false"},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

Ловушка: у `thetaSketch` в `postAggregations` работает `finalizingFieldAccess`,
а не `fieldAccess` и не вложенный `thetaSketchEstimate` — последний падает с
«name is null».

---

## 2. Доля встреч, дошедших до саммари

**Главное число продукта, и до 2026-08-20 его не существовало.**
`Recap.finished` уходит на каждой попытке (встреча без провайдера паркуется, и
лестница возвращается к ней) и ещё раз при перегенерации после правки, поэтому
`eventCount` считает выдачи, а не встречи. Флаг `first=1` отмечает первый
конспект для встречи — по нему и считается.

Фильтр по версиям обязателен: `first` шлют только сборки 1.16.6+, а
`Recording.finished` шлют все. Без фильтра знаменатель включает встречи со
старых сборок, и доля падает втрое.

**2026-08-26: 259 встреч, 199 первых конспектов, 77 %.**
Без фильтра по версиям тот же запрос отдаёт 660 / 198 / 30 % — это артефакт,
а не регресс.

```json
{
  "queryType": "timeseries",
  "granularity": "all",
  "aggregations": [
    {"type": "filtered",
     "filter": {"type": "selector", "dimension": "type", "value": "Propeller.Recording.finished"},
     "aggregator": {"type": "longSum", "fieldName": "count", "name": "meetings"}},
    {"type": "filtered",
     "filter": {"type": "and", "fields": [
       {"type": "selector", "dimension": "type", "value": "Propeller.Recap.finished"},
       {"type": "selector", "dimension": "result", "value": "ok"},
       {"type": "selector", "dimension": "first", "value": "1"}
     ]},
     "aggregator": {"type": "longSum", "fieldName": "count", "name": "summaries"}}
  ],
  "postAggregations": [
    {"type": "arithmetic", "name": "share", "fn": "/",
     "fields": [
       {"type": "fieldAccess", "fieldName": "summaries"},
       {"type": "fieldAccess", "fieldName": "meetings"}
     ]}
  ],
  "filter": {"type": "and", "fields": [
    {"type": "selector", "dimension": "isTestMode", "value": "false"},
    {"type": "or", "fields": [
      {"type": "selector", "dimension": "TelemetryDeck.AppInfo.version", "value": "1.16.6"},
      {"type": "selector", "dimension": "TelemetryDeck.AppInfo.version", "value": "1.16.7"},
      {"type": "selector", "dimension": "TelemetryDeck.AppInfo.version", "value": "1.16.8"}
    ]}
  ]},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

**Список версий надо дополнять с каждым релизом**, иначе инсайт тихо перестанет
видеть новые сборки. Когда 1.16.5 и старше вымрут — фильтр по версиям снять.

Ловушка: короткий `eventCount` **не работает внутри** `filtered`-агрегатора,
нужен `longSum` по полю `count`.

---

## 3. Ожидание, которое человек почувствовал

Секунды от конца встречи до готового конспекта, только для встреч этой сессии
(`awaited=1`), разрезом по длине встречи. Читать медиану и p90: распределение
с тяжёлым хвостом, среднее по нему врёт вдвое.

**2026-08-26, медиана / p90, секунды:**

| Длина встречи | Медиана | p90 | Событий |
|---|---|---|---|
| `<1m` | 32 | 3 139 | 29 |
| `1-15m` | 105 | 1 267 | 77 |
| `15-60m` | 275 | 3 273 | 203 |
| `60m+` | 614 | 12 199 | 28 |

Лабораторный замер прохода — 82 с на 17-минутной встрече (`STATE.md` §12).
Разница между ним и медианой 275 с — это очередь, ретраи и сон машины.

```json
{
  "queryType": "groupBy",
  "granularity": "all",
  "dimensions": [{"type": "default", "dimension": "meeting", "outputName": "meeting", "outputType": "STRING"}],
  "aggregations": [
    {"type": "quantilesDoublesSketch", "fieldName": "floatValue", "name": "_q", "k": 128},
    {"type": "eventCount", "name": "events"}
  ],
  "postAggregations": [
    {"type": "quantilesDoublesSketchToQuantile", "name": "median_s", "fraction": 0.5,
     "field": {"type": "fieldAccess", "fieldName": "_q"}},
    {"type": "quantilesDoublesSketchToQuantile", "name": "p90_s", "fraction": 0.9,
     "field": {"type": "fieldAccess", "fieldName": "_q"}}
  ],
  "filter": {"type": "and", "fields": [
    {"type": "selector", "dimension": "type", "value": "Propeller.Summary.waited"},
    {"type": "selector", "dimension": "awaited", "value": "1"},
    {"type": "selector", "dimension": "isTestMode", "value": "false"}
  ]},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

---

## 4. Ложный автозапуск

Записи, которые человек выбросил. Корзина `source=auto, age=<10s` — это неверный
детект созвона; всё остальное — передумал.

**2026-08-26: `auto` — ноль событий.** Из размеченных 8 — все `manual`
(`<10s` 1, `10-60s` 2, `5m+` 5); ещё 11 событий с 6 машин пришли со старых
сборок без параметров.

Ноль читается двояко: либо детект не стреляет ложно, либо человек не находит
«Не записывать». Развести это можно только теневой пробой (`STATE.md`:557).

```json
{
  "queryType": "groupBy",
  "granularity": "all",
  "dimensions": [
    {"type": "default", "dimension": "source", "outputName": "source", "outputType": "STRING"},
    {"type": "default", "dimension": "age", "outputName": "age", "outputType": "STRING"}
  ],
  "aggregations": [
    {"type": "eventCount", "name": "events"},
    {"type": "thetaSketch", "fieldName": "clientUser", "name": "machines"}
  ],
  "filter": {"type": "and", "fields": [
    {"type": "selector", "dimension": "type", "value": "Propeller.Recording.cancelled"},
    {"type": "selector", "dimension": "isTestMode", "value": "false"}
  ]},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

---

## 5. Читает ли архив агент

`Claude.used` — единственный сигнал про использование фичи: `Claude.setup`
говорит лишь о нажатой кнопке. В `floatValue` число вызовов, в `tool` — имя
инструмента.

**2026-08-26: 25 событий с 4 машин, 44 вызова.** По инструментам:
`search_meetings` 18 вызовов (4 машины), `get_transcript` 12 (3),
`get_recap` 12 (3), `find_open_questions` 2 (2). То есть архив ищут и читают
целиком, а не только просят конспект.

```json
{
  "queryType": "groupBy",
  "granularity": "all",
  "dimensions": [
    {"type": "default", "dimension": "tool", "outputName": "tool", "outputType": "STRING"},
    {"type": "default", "dimension": "frequency", "outputName": "frequency", "outputType": "STRING"}
  ],
  "aggregations": [
    {"type": "eventCount", "name": "events"},
    {"type": "thetaSketch", "fieldName": "clientUser", "name": "machines"},
    {"type": "doubleSum", "fieldName": "floatValue", "name": "calls"}
  ],
  "filter": {"type": "and", "fields": [
    {"type": "selector", "dimension": "type", "value": "Propeller.Claude.used"},
    {"type": "selector", "dimension": "isTestMode", "value": "false"}
  ]},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

---

## Шестая плашка: не метрика, а сигнализация

`Invariant.broken` и `Pipeline.failed` в пятёрку не входят: там любое ненулевое
значение — баг у живого человека, а не число, которое куда-то движется.

**2026-08-26: `Pipeline.failed` — 282 события на 11 машинах, `Invariant.broken`
— ноль.** Двести восемьдесят два это много: смотреть разрезом по `phase` и
`kind`.

```json
{
  "queryType": "topN",
  "granularity": "all",
  "threshold": 20,
  "dimension": {"type": "default", "dimension": "type", "outputName": "signal", "outputType": "STRING"},
  "metric": {"type": "numeric", "metric": "events"},
  "aggregations": [
    {"type": "eventCount", "name": "events"},
    {"type": "thetaSketch", "fieldName": "clientUser", "name": "machines"}
  ],
  "filter": {"type": "and", "fields": [
    {"type": "selector", "dimension": "isTestMode", "value": "false"},
    {"type": "or", "fields": [
      {"type": "selector", "dimension": "type", "value": "Propeller.Invariant.broken"},
      {"type": "selector", "dimension": "type", "value": "Propeller.Pipeline.failed"},
      {"type": "selector", "dimension": "type", "value": "Propeller.Notch.bladeDrive"}
    ]}
  ]},
  "relativeIntervals": [{"beginningDate": {"component": "day", "offset": -30, "position": "beginning"},
                          "endDate": {"component": "day", "offset": 0, "position": "end"}}]
}
```

---

## Чего в дашборде нет намеренно

- **«Всего пользователей».** Такой метрики не существует: любая плашка считает
  уникальных за выбранный период, и на скользящем окне она падает без всяких
  удалений. Плюс данных старше 2026-07-27 нет вовсе — их стёр бесплатный план
  до подписки, и апгрейд их не вернул.
- **Удаления.** Клиентская аналитика живёт внутри приложения; удалённое
  приложение молчит. Уход виден как отсутствие, никогда как событие.
- **Проценты с десятыми.** Машин семьдесят с небольшим: одна машина — это
  полтора процентных пункта.
