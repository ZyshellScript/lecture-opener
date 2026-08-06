# Mohadiri — Lecture Opener

Automatically opens your online lectures in Google Chrome at the right time, then clicks the **Join** button so you're inside the meeting before you even touch the keyboard.

No Python, no Node, no dependencies — just PowerShell and Chrome.

## How it works

1. You manage everything from a **full Windows app (GUI)** — no terminal, no editing scripts.
2. The app saves your schedules to `data.json`.
3. Press **تشغيل** in the app and the engine (`lecture-opener.ps1`) runs in the background: it checks the time every 15 seconds, opens Chrome (fullscreen, with a dedicated automation profile) when a lecture is due, and sends a **real mouse click** to the Join button (`Join now` / `Ask to join` / `Switch here`, English or Arabic).
4. It keeps clicking until the Join button disappears (you're in the meeting). Everything is logged to `log.txt`, shown live inside the app.

For lectures whose links change every session, use **Classroom mode**: the engine opens Google Classroom, finds the class by name, reads the class stream, and picks up the meeting link **posted today** (never a link from an old post).

## Getting started

### 1. Run the app

Double-click `start.bat`. The app window opens with four tabs:

| Tab | What you can do |
|-----|-----------------|
| **الرئيسية** | Start / restart / stop the engine, see live log, next lecture, active profile |
| **المحاضرات** | Add / edit / delete lectures (subject, day, time, link, Classroom mode, advance/delay) |
| **البروفايلات** | Manage universities / Google accounts (each with its own Chrome profile) |
| **الإعدادات** | Pick your timezone, see the Chrome path and data file |

Changes are saved to `data.json` immediately — **you never edit a script manually**.

### 2. Add your schedule

From the **المحاضرات** tab pick a profile (or add one in **البروفايلات**), then **إضافة محاضرة**:

- `name` — subject name (shown in the log)
- `link` — the meeting link (leave empty when mode is Classroom)
- `day` — the day of the week
- `time` — 24-hour format (`08:00` = 8 AM, `21:00` = 9 PM)
- `mode` — **رابط مباشر** opens the saved link directly; **جوجل كلاسروم** looks the link up in Google Classroom
- `classroom` — the exact class name as shown in Google Classroom (only for Classroom mode)
- `advance` / `delay` — open this many minutes before / after the time (`0` = exactly on time)

### 3. Sign in to your Google account once

The engine uses a separate Chrome profile so it never touches your normal Chrome.

1. In the app, open the **البروفايلات** tab and press **تسجيل دخول Chrome (مرة واحدة)** (or double-click `login-profile.bat`).
2. Sign in with the Google account for that profile.
3. Close Chrome.

### 4. Start it

Press **تشغيل** in the app and leave it running. That's it. Press **إيقاف** to stop.

> If the engine is already running and you change the schedule, press **إعادة تشغيل** so it picks up the new table.

## Files

| File | Purpose |
|------|---------|
| `start.bat` | Opens the app (GUI) |
| `lecture-opener-gui.ps1` | The app — full interface for schedules, profiles, settings, log |
| `lecture-opener.ps1` | The engine (reads `data.json`, runs the meeting automation) |
| `data.json` | Your schedules & profiles (created/edited by the app — never push this) |
| `config.json` | Last profile + timezone (kept in sync by the app) |
| `login-profile.bat` / `login-profile.ps1` | Opens the automation Chrome so you can sign in once |
| `diagnose.bat` / `diagnose.ps1` | Helpers to inspect the meeting page buttons if Join is not detected |

## Requirements

- Windows
- Google Chrome installed
- PowerShell (comes with Windows)

## Security note

Your real meeting links and your Chrome profile (with your Google account) stay **local only**. They are listed in `.gitignore` and are never pushed to this repository.
