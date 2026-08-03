@echo off
chcp 65001 >nul
title Mohadiri - Lecture Opener
where wt >nul 2>nul
if not errorlevel 1 (
    start "" wt powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lecture-opener.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lecture-opener.ps1"
)
