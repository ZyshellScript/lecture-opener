# Lecture Opener

Automatically opens your online lectures in Google Chrome at the right time, then clicks the **Join** button so you're inside the meeting before you even touch the keyboard.

No Python, no Node, no dependencies — just PowerShell and Chrome.

## How it works

1. The script runs a loop and checks the time every 15 seconds.
2. The first time you run it, it asks which country/timezone you're in and saves it to `config.json` (works for any country — no more hardcoded Egypt time).
2. When it's time for a lecture, it launches Chrome (fullscreen) with a dedicated automation profile.
3. It connects to Chrome via the DevTools Protocol and sends a **real mouse click** to the Join button (`Join now` / `Ask to join` / `Switch here`, English or Arabic).
4. It keeps clicking until the Join button disappears from the screen (meaning you're in the meeting).
5. Everything is logged to `log.txt`.

For lectures whose links change every session, use **Classroom mode**: the script opens
Google Classroom, finds the class by name, reads the class stream, and picks up the meeting
link **posted today** (it never opens a link from an old post).

## Setup

### 1. Put your schedule in the script

Edit the `$profiles` list at the top of `lecture-opener.ps1`. One profile = one university / Google account:

```powershell
$profiles = @(
    @{
        name          = "My University"
        account       = "me@uni.edu"
        chromeProfile = "chrome-profile"
        schedule      = @(
            @{ name = "Math";    link = "https://meet.google.com/xxx-xxxx-xxx"; day = "Monday";    time = "10:00"; advance = 0; delay = 0; mode = "link";      classroom = "" }
            @{ name = "Physics"; link = "";                                    day = "Wednesday"; time = "13:30"; advance = 0; delay = 0; mode = "classroom"; classroom = "Physics" }
        )
    }
)
```

Lecture fields (inside a profile's `schedule`):
- `name` — subject name (just for the log)
- `link` — the meeting link (leave empty when `mode = "classroom"`)
- `day` — `Sunday` ... `Saturday` (abbreviations like `Mon` also work)
- `time` — 24-hour format (`08:00` = 8 AM, `21:00` = 9 PM)
- `advance` — open this many minutes **before** the time (`0` = exactly on time)
- `delay` — open this many minutes **after** the time
- `mode` — `"link"` opens the saved link directly; `"classroom"` looks the link up in Google Classroom
- `classroom` — the exact class name as shown in Google Classroom (only used in `"classroom"` mode)

Profile fields:
- `name` — profile name shown in the prompt / log
- `account` — the Google account used for this university
- `chromeProfile` — folder (next to the script) holding that account's Chrome login
- `schedule` — that university's lecture list

**Multiple universities:** add a second block (with its own `account`, its own
`chromeProfile` folder like `chrome-profile2`, and its own schedule). When the script starts it
will ask **which profile** to use. With only one profile it runs silently, no question.
Each account is signed in separately via `login-profile.bat` (it lists all profiles).

### 2. Sign in to your Google account once

The automation uses separate Chrome profiles so it never touches your normal Chrome. To sign in once:

1. Double-click `login-profile.bat`
2. Sign in with your Google account
3. Close Chrome

### 3. Run it

Double-click `start.bat` and leave it running. That's it.

## Files

| File | Purpose |
|------|---------|
| `lecture-opener.ps1` | The main script (rename from the example and add your links) |
| `lecture-opener.example.ps1` | Template with placeholder links |
| `start.bat` | Launches the script in Windows Terminal |
| `login-profile.bat` | Opens the automation Chrome so you can sign in once |
| `diagnose.bat` / `diagnose.ps1` | Helpers to inspect the meeting page buttons if Join is not detected |

## Requirements

- Windows
- Google Chrome installed
- PowerShell (comes with Windows)

## Security note

Your real meeting links and your Chrome profile (with your Google account) stay **local only**. They are listed in `.gitignore` and are never pushed to this repository.
