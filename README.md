# BambooTime

A small macOS 14+ menu bar app for BambooHR time tracking. The menu bar
shows whether you're clocked in and how long you've worked today; the menu
lets you clock in and out and lists today's entries with today's and this
week's totals. Personal build: no dependencies, no Apple Developer account.

"Total this week" matches BambooHR's own weekly figure: clocked time, manually
entered hours, and approved time off (day-based time off counts with the
company's hours for that weekday). If time off can't be read, the line says
"(excl. time off)".

## Build & install

Needs Xcode and an OAuth app on
[developers.bamboohr.com](https://developers.bamboohr.com) (free, self-service):
redirect URI `bambootime://oauth`, scopes `offline_access`, `employee:name`,
`time_tracking`, `time_tracking:timesheets.write` and `time_off`. Put its
credentials in `.env` (git-ignored):

```sh
BAMBOO_CLIENT_ID="…"
BAMBOO_CLIENT_SECRET="…"   # omit if the app is a public (PKCE-only) client
# BAMBOO_REDIRECT_URI="…"  # only if the portal rejects bambootime://oauth
```

The secret ships inside the app, so treat the build as internal.

```sh
scripts/bundle.sh 0.1        # → build/BambooTime.dmg
open build/BambooTime.dmg    # drag BambooTime to Applications
```

Update: `git pull && scripts/bundle.sh 0.2`, quit BambooTime, drag the new copy
over the old one. After each update macOS asks once to allow Keychain access
to the sign-in token: click **Always Allow**. To stop that prompt, create a
self-signed code-signing certificate (Keychain Access → Certificate Assistant
→ Create a Certificate, type "Code Signing") and build with
`SIGN_IDENTITY="<cert name>" scripts/bundle.sh 0.2`, or put
`SIGN_IDENTITY="<cert name>"` in `.env` (git-ignored) to make it the default.



If the DMG ever arrives via browser or AirDrop, run
`xattr -dr com.apple.quarantine /Applications/BambooTime.app` once.

## Setup

Menu bar gear icon → **Settings…**:
- **Company domain**: `mycompany` from `mycompany.bamboohr.com`
- **Sign In**: log in to BambooHR in the browser sheet and allow access. The
  refresh token is stored in the Keychain.

Your employee id is detected automatically. Requires Time Tracking with clock
in/out enabled for your account. Turn on **Launch at Login** from the copy in
Applications.

## Menu bar states

| Icon            | Meaning                                    |
| --------------- | ------------------------------------------ |
| ⚙               | Not configured                             |
| ◌               | Loading                                    |
| green ● 4h 12m  | Clocked in, total today                    |
| ○ 3h 05m        | Not clocked in, total today                |
| ⚠               | Error and no data (details in the menu)    |

Refreshes every 60 s while clocked in, every 5 min otherwise, and on menu open.
On 401/403 auto-refresh pauses (BambooHR locks keys after repeated failures);
use **Refresh** after signing in again.

## Repository

`Sources/BambooTime/` is the app, `Tests/` the unit and live tests, `scripts/`
the DMG build and icon generator, and `Support/` holds `Info.plist` and the
icon. [PLAN.md](PLAN.md) is the implementation spec: behavior, BambooHR API
facts, calculation rules and design decisions.

## Development

```sh
swift test                     # unit tests (live test skipped)
set -a; . ./.env; set +a; BAMBOO_DOMAIN=mycompany \
  swift test --filter live     # real API with the app's stored sign-in: prints this week's entries and total
# add BAMBOO_EXPECT_WEEK="47h 50m" to assert BambooHR's weekly total
swift run                      # run unbundled (Keychain and Launch at Login need the .app)
swift scripts/make-icon.swift  # regenerate Support/AppIcon.icns
```

If `xcode-select` points at the Command Line Tools, prefix these with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (`bundle.sh` does that itself).


## License

[Sustainable Use License 1.0](LICENSE.md): use and change it for personal,
non-commercial or your own internal business purposes (so employees can use it
at work). Share it only free of charge for non-commercial purposes. Selling it
or using it in commercial products isn't allowed. Provided as is, without any
warranty or liability.
