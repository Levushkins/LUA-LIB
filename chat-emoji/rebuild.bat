@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

rem ---------------------------------------------------------------------------
rem rebuild.bat — собирает набор смайлов из ВАШЕГО _chat.asi и ВАШЕГО
rem Segoe UI Emoji. Тогда иконки выглядят один в один как в чате Arizona RP.
rem
rem Делает всё сам:
rem   1. находит Python и ставит Pillow
rem   2. находит _chat.asi и распаковывает из него шрифты и списки смайлов
rem   3. находит эмодзи-шрифт и собирает атлас
rem
rem Запуск: двойным кликом, либо с явными путями
rem     rebuild.bat "C:\...\_chat.asi" "C:\Windows\Fonts\seguiemj.ttf"
rem ---------------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo === Сборка набора смайлов ===
echo.

rem --- Python ---------------------------------------------------------------
set PY=
where py >nul 2>&1 && set PY=py -3
if "%PY%"=="" (
    where python >nul 2>&1 && set PY=python
)
if "%PY%"=="" (
    echo [!] Python не найден.
    echo     Поставьте его с https://www.python.org/downloads/
    echo     и обязательно отметьте галочку "Add Python to PATH".
    pause
    exit /b 1
)
echo [1/5] Python: %PY%

rem --- Pillow ---------------------------------------------------------------
%PY% -c "import PIL" >nul 2>&1
if errorlevel 1 (
    echo [2/5] Ставлю Pillow...
    %PY% -m pip install --quiet --upgrade pillow
    if errorlevel 1 (
        echo [!] Не удалось поставить Pillow.
        pause
        exit /b 1
    )
) else (
    echo [2/5] Pillow уже есть
)

rem --- _chat.asi ------------------------------------------------------------
set ASI=%~1
if not "%ASI%"=="" goto :got_asi
for %%D in ("%~dp0..\.." "%~dp0.." "%~dp0" "%~dp0..\..\..") do (
    if exist "%%~fD\_chat.asi" (
        set ASI=%%~fD\_chat.asi
        goto :got_asi
    )
)

:got_asi
if "%ASI%"=="" (
    if exist "data\emoji.json" (
        echo [3/5] _chat.asi не найден, беру готовый data\emoji.json
    ) else (
        echo [!] Не нашёл ни _chat.asi, ни data\emoji.json.
        echo     Укажите путь вручную:
        echo         rebuild.bat "C:\...\bin\arizona\_chat.asi"
        pause
        exit /b 1
    )
) else (
    echo [3/5] _chat.asi: !ASI!
    %PY% tools\extract_chat_emoji.py "!ASI!" -o data
    if errorlevel 1 (
        echo [!] Не удалось разобрать _chat.asi.
        pause
        exit /b 1
    )
)

rem --- эмодзи-шрифт ---------------------------------------------------------
set FONT=%~2
if not "%FONT%"=="" goto :got_font

rem сам чат предпочитает свой fontcustom, если он лежит рядом с игрой
for %%D in ("%~dp0..\.." "%~dp0.." "%~dp0") do (
    if exist "%%~fD\moonloader\fontcustom\seguiemj_1.45.ttf" (
        set FONT=%%~fD\moonloader\fontcustom\seguiemj_1.45.ttf
        goto :got_font
    )
    if exist "%%~fD\fontcustom\seguiemj_1.45.ttf" (
        set FONT=%%~fD\fontcustom\seguiemj_1.45.ttf
        goto :got_font
    )
)
if exist "%WINDIR%\Fonts\seguiemj.ttf" set FONT=%WINDIR%\Fonts\seguiemj.ttf

:got_font
if "%FONT%"=="" (
    echo [!] Не нашёл эмодзи-шрифт.
    echo     Укажите его вручную вторым аргументом:
    echo         rebuild.bat "" "C:\Windows\Fonts\seguiemj.ttf"
    pause
    exit /b 1
)
echo [4/5] Шрифт: !FONT!

rem --- сборка ---------------------------------------------------------------
echo [5/5] Собираю атлас...
%PY% tools\build_emoji_atlas.py data\emoji.json ^
    --icons data\icons.ttf ^
    --big-icons data\big_icons.ttf ^
    --emoji "!FONT!" ^
    -o moonloader\resource\chat_emoji ^
    --cell 40 --width 2048
if errorlevel 1 (
    echo [!] Сборка не удалась.
    pause
    exit /b 1
)

echo.
echo Готово. Скопируйте в папку moonloader:
echo     moonloader\lib\chat_emoji.lua
echo     moonloader\resource\chat_emoji\chat_emoji.png
echo     moonloader\resource\chat_emoji\chat_emoji_atlas.lua
echo.
pause
