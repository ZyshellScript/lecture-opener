@echo off
chcp 65001 >nul
title Mohadiri - Diagnose
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
