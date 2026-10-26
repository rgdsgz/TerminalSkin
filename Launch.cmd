@echo off
rem TerminalGlass launcher
rem No args  -> open the GUI (console hidden)
rem With args -> run in console mode, e.g.:
rem    Launch.cmd -Apply -Opacity 85
rem    Launch.cmd -Reset
rem    Launch.cmd -Status

if "%~1"=="" (
    start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0TerminalGlass.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TerminalGlass.ps1" %*
)
