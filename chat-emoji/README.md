# Смайлы из `_chat.asi` в mimgui

Разбор плагина чата Arizona Games (`_chat.asi`), извлечение всех **825 смайлов**
и готовый модуль для их отрисовки и использования в mimgui.

---

## 1. Что внутри `_chat.asi`

`_chat.asi` — это PE32 DLL (ImGui + FreeType + lunasvg, PDB-путь
`C:\source\imgui-chat\...\_chat.pdb`). Смайлы там лежат в трёх местах:

### Таблица смайлов

В `.data` по адресу `0x100E1FF0` лежит массив из 825 структур:

```c
struct { const char* name; uint32_t codepoint; };
```

Например `{"smiley", 0x1F603}`, `{"arz", 0x1FC08}`, `{":)", 0x1F642}`.
Порядок в массиве совпадает с порядком в панели смайлов чата.

### Шрифты

Четыре шрифта лежат в ресурсах `RCDATA` в **сжатом виде**. Формат сжатия —
`stb_compress` (сигнатура `0x57bC0000`), тот самый, что выдаёт утилита ImGui
`binary_to_compressed_c`:

| ресурс | шрифт | что содержит |
|--------|-------|--------------|
| 101 | Arial Bold | текст чата |
| 102 | Heading Now Medium | заголовки |
| 103 | **icons** (COLR + CPAL + SVG) | серверные иконки: `U+F003…U+F341`, `U+1FC00…U+1FC38`, буквы-плашки `U+1F1E6…U+1F1FF` |
| 104 | **big_icons** (COLR + CPAL) | крупные иконки интерфейса |

### Стандартные смайлы

Их в плагине **нет**. `U+1F600` и соседей чат берёт из системного
**Segoe UI Emoji**: читает реестр
`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` → `Segoe UI Emoji (TrueType)`
→ `%WINDIR%\Fonts\seguiemj.ttf`, а если рядом лежит
`fontcustom\seguiemj_1.45.ttf` — берёт его.

### Как смайл попадает в текст

Токеном `:u<hex>:` — формат `":u%x:"` в бинарнике. То есть 😃 в строке чата
выглядит как `:u1f603:`. Рядом живут `:item%d:` и `:slot%d_%d:` для предметов.

---

## 2. Почему смайлы нельзя просто подключить шрифтом

Напрашивается `AddFontFromFileTTF('seguiemj.ttf', ...)`, но так не выйдет —
по двум независимым причинам:

1. **mimgui собран со `stb_truetype`.** Он растеризует только контуры `glyf` и
   ничего не знает про `COLR`/`CPAL` и `SVG `. У цветных шрифтов базовый контур
   глифа обычно пустой — весь рисунок лежит в цветных слоях. На выходе получатся
   пустые прямоугольники.
2. **`ImWchar` в mimgui 16-битный.** Смайлы живут в `U+1F300…U+1FAFF`, то есть
   выше `U+FFFF`. Такие кодовые точки в 16-битный тип физически не влезают, и
   `GlyphRanges` их не примет.

Поэтому рабочий путь ровно один: **заранее растеризовать смайлы в текстуру**
и рисовать их через `imgui.Image` / draw list. Этим и занимаются скрипты ниже.

---

## 3. Что здесь лежит

```
chat-emoji/
├── tools/
│   ├── extract_chat_emoji.py   распаковка ресурсов и таблицы из _chat.asi
│   ├── build_emoji_atlas.py    растеризация смайлов в PNG-атлас
│   └── test_chat_emoji.lua     самопроверка модуля (luajit, без игры)
├── data/
│   ├── icons.ttf               распакован из ресурса 103
│   ├── big_icons.ttf           распакован из ресурса 104
│   ├── emoji.json              825 смайлов: имя, код, категория
│   └── emoji_list.lua          то же самое таблицей Lua
└── moonloader/                 готово к копированию в папку moonloader
    ├── chat_emoji_demo.lua     пример: /emj
    ├── lib/chat_emoji.lua      модуль
    └── resource/chat_emoji/
        ├── chat_emoji.png      атлас 2048×1024, ячейка 48 px
        └── chat_emoji_atlas.lua описание с координатами
```

---

## 4. Установка

Скопируйте содержимое `moonloader/` в папку `moonloader` в каталоге игры:

```
moonloader/chat_emoji_demo.lua
moonloader/lib/chat_emoji.lua
moonloader/resource/chat_emoji/chat_emoji.png
moonloader/resource/chat_emoji/chat_emoji_atlas.lua
```

Зайдите в игру и введите `/emj`.

> **Про внешний вид.** Готовый атлас в репозитории собран на **Noto Color Emoji**,
> потому что Segoe UI Emoji — системный шрифт Windows и распространять его нельзя.
> Смайлы будут те же самые и с теми же кодами, но нарисованы в стиле Noto.
> Чтобы получить ровно тот вид, что в чате, пересоберите атлас на своём
> `seguiemj.ttf` — см. раздел 6.

---

## 5. Использование

```lua
local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

imgui.OnInitialize(function()
    local ok, err = emoji.load()      -- грузит атлас и создаёт текстуру
    if not ok then print(err) end
end)
```

### Нарисовать смайл

```lua
emoji.image('smiley', 24)     -- по имени
emoji.image(0x1F603, 24)      -- по кодовой точке
emoji.image(':u1f603:', 24)   -- по токену
```

### Кнопка со смайлом

```lua
if emoji.button('arz', 32) then
    print('нажали на логотип Arizona')
end
```

### Текст со смайлами внутри

```lua
emoji.text(u8'привет :u1f603: как дела :u1f44b:')
```

`emoji.text` разбирает строку на куски, текст рисует через `TextUnformatted`,
а смайлы — картинками, центруя их по высоте строки.

### Панель выбора

```lua
local picked = emoji.picker('grid', 24, 300)   -- id, размер, высота
if picked then
    sampSendChat(emoji.encode(picked))         -- отправит ':u1f603:'
end
```

Панель — это поиск по имени плюс сетка, разбитая на 14 категорий
(Смайлы, Животные, Люди, Еда, Транспорт, Сервер, Буквы и т.д.).

### Отправить смайл в чат

```lua
sampSendChat('всем привет ' .. emoji.encode('smiley'))
```

Плагин чата сам подменит `:u1f603:` на картинку — и у вас, и у остальных
игроков с этим плагином.

### Полный список API

| функция | описание |
|---------|----------|
| `emoji.load([dir])` | загрузить атлас и текстуру; `true` либо `false, ошибка` |
| `emoji.unload()` | освободить текстуру (в `onScriptTerminate`) |
| `emoji.get(key)` | запись по имени, коду, токену или самой записи |
| `emoji.encode(key)` | токен `:uXXXX:` для чата |
| `emoji.parse(str)` | разбор строки на куски текста и смайлы |
| `emoji.image(key, size)` | нарисовать картинкой |
| `emoji.button(key, size, [id])` | кнопка, возвращает `true` при нажатии |
| `emoji.text(str, [size])` | текст с подстановкой смайлов |
| `emoji.picker(id, [size], [height])` | панель выбора, возвращает запись либо `nil` |
| `emoji.list` | массив всех 825 записей по порядку из чата |
| `emoji.byName`, `emoji.byCp` | таблицы поиска |
| `emoji.categories` | `{ { name = 'Смайлы', items = {...} }, ... }` |

Запись смайла:

```lua
{ name = 'smiley', cp = 0x1F603, cat = 'Смайлы',
  slot = 20, index = 21, token = ':u1f603:',
  uv0 = ImVec2(...), uv1 = ImVec2(...) }
```

---

## 6. Пересборка

### Извлечь всё заново из `_chat.asi`

```bash
python3 tools/extract_chat_emoji.py /путь/к/_chat.asi -o data
```

Зависимостей нет — только стандартная библиотека Python. Скрипт сам разбирает
PE, распаковывает `stb_compress` и находит таблицу смайлов.

### Собрать атлас на своём Segoe UI Emoji

```bash
pip install pillow

python3 tools/build_emoji_atlas.py data/emoji.json \
    --icons data/icons.ttf \
    --emoji "C:/Windows/Fonts/seguiemj.ttf" \
    -o moonloader/resource/chat_emoji \
    --cell 48
```

Если `--emoji` не указать, скрипт сам поищет `%WINDIR%\Fonts\seguiemj.ttf`.

Полезные ключи:

* `--cell 64` — крупнее ячейка, чётче при большом размере, но тяжелее текстура
* `--width 2048` — ширина атласа (высота подбирается сама, до степени двойки)
* `--pad 2` — отступ внутри ячейки

Серверные иконки (`U+F2xx`, `U+1FCxx`, буквы-плашки) всегда берутся из
`icons.ttf`, остальное — из эмодзи-шрифта.

### Проверить модуль

```bash
luajit tools/test_chat_emoji.lua
```

Тест подменяет mimgui и API MoonLoader, проверяет описание атласа, UV-координаты,
поиск и разбор строк — игра для этого не нужна.

---

## 7. Как это работает внутри

**Текстура.** `chat_emoji.lua` читает PNG в память и создаёт текстуру D3D9 через
`D3DXCreateTextureFromFileInMemoryEx` из `d3dx9_XX.dll` (перебираются версии
43…24), передавая устройство из `getD3DDevicePtr()`. Пул — `D3DPOOL_MANAGED`,
поэтому текстура переживает device reset и пересоздавать её при смене разрешения
не нужно.

**UV.** В описании у каждого смайла хранится только номер ячейки `slot`,
а координаты считаются на загрузке:

```lua
col  = slot % cols
line = math.floor(slot / cols)
uv0  = ImVec2(col * cell / width, line * cell / height)
```

**Кнопки.** `emoji.button` сделана на `InvisibleButton` + draw list, а не на
`ImageButton`. Причина: у всех кнопок одна и та же текстура, а `ImageButton`
берёт ID именно из неё — вся сетка слиплась бы в один элемент. Побочная польза:
код не зависит от того, какая сигнатура `ImageButton` в конкретной сборке mimgui.

**Растеризация.** У цветных шрифтов базовый контур глифа пустой, поэтому Pillow
на строке из одного такого символа считает высоту маски нулевой и не рисует
ничего. `build_emoji_atlas.py` обходит это, дорисовывая справа символ, которого в
шрифте заведомо нет (`U+E123`): он рисуется как `.notdef` с непустым контуром,
маска получает нормальную высоту, а сам `.notdef` отрезается по ширине аванса.

---

## 8. Про распространение

`icons.ttf`, `big_icons.ttf` и собранный атлас содержат графику Arizona Games,
вытащенную из их плагина. Это материал для личного использования и разбора —
не выкладывайте его как своё и не продавайте.

Шрифты Arial и Heading Now из ресурсов 101 и 102 в репозиторий не попали
намеренно: это коммерческие шрифты. При необходимости их достанет
`extract_chat_emoji.py`.
