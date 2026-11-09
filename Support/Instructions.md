# BambooTime

## Install

Drag **BambooTime** onto **Applications**.

## First run

BambooTime isn't notarized by Apple, so macOS may block the first launch.

1. Open BambooTime from Applications. If macOS says it can't be opened,
   click **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll down to the message
   about BambooTime and click **Open Anyway**, then confirm.

Or run this once in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/BambooTime.app
```

BambooTime has no Dock icon: it lives in the menu bar. On first launch the
settings dialog opens by itself.

## Setup

Click the menu bar icon → **Settings…**:

- **Company domain**: `mycompany` from `mycompany.bamboohr.com`
- Click **Sign In**. BambooHR opens in a browser sheet: log in as usual and
  click **Allow Access**.

When macOS asks to allow Keychain access, click **Always Allow**. Turn on **Launch at Login** in the menu if you like.
