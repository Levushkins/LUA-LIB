@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

rem ---------------------------------------------------------------------------
rem rebuild.bat - пересобирает атлас смайлов на ВАШЕМ Segoe UI Emoji, чтобы
rem иконки выглядели один в один как в чате Arizona RP.
rem
rem Готовый атлас в репозитории собран на Noto Color Emoji: Segoe UI Emoji -
rem системный шрифт Windows, распространять его нельзя. Коды и порядок те же,
rem отличается только рисовка. Этот скрипт берёт шрифт с вашей машины.
rem
rem Запуск: двойным кликом, либо
rem     rebuild.bat "C:\путь\к\seguiemj.ttf"
rem ---------------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo === Пересборка атласа смайлов ===
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
echo [1/4] Python: %PY%

rem --- Pillow ---------------------------------------------------------------
%PY% -c "import PIL" >nul 2>&1
if errorlevel 1 (
    echo [2/4] Ставлю Pillow...
    %PY% -m pip install --quiet --upgrade pillow
    if errorlevel 1 (
        echo [!] Не удалось поставить Pillow.
        pause
        exit /b 1
    )
) else (
    echo [2/4] Pillow уже есть
)

rem --- шрифт ----------------------------------------------------------------
set FONT=%~1
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
    echo     Укажите его вручную:  rebuild.bat "C:\Windows\Fonts\seguiemj.ttf"
    pause
    exit /b 1
)
echo [3/4] Шрифт: %FONT%

rem --- сборка ---------------------------------------------------------------
echo [4/4] Собираю атлас...
%PY% tools\build_emoji_atlas.py data\emoji.json ^
    --icons data\icons.ttf ^
    --emoji "%FONT%" ^
    -o moonloader\resource\chat_emoji ^
    --cell 48 --width 2048
if errorlevel 1 (
    echo [!] Сборка не удалась.
    pause
    exit /b 1
)

echo.
echo Готово. Скопируйте в игру с заменой:
echo     moonloader\resource\chat_emoji\chat_emoji.png
echo     moonloader\resource\chat_emoji\chat_emoji_atlas.lua
echo.
pause
