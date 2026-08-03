@echo off
chcp 65001 >nul
title Mohadiri - Sign in once
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0login-profile.ps1"
pause
