@echo off
chcp 65001 >nul
title Mohadiri - Sign in once
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" --user-data-dir="C:\Lectures\chrome-profile" --remote-debugging-port=9222 --no-first-run --no-default-browser-check --remote-allow-origins=*
