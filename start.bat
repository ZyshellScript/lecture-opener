@echo off
chcp 65001 >nul
title Mohadiri - Lecture Opener
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0lecture-opener-gui.ps1"
