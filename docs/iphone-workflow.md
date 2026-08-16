# iPhone development workflow

## Physical-device screenshots on iOS 26

Use Xcode's current CoreDevice screenshot path. `idevicescreenshot` does not
work reliably with the personalized Developer Disk Image used by iOS 26.

1. Open `ios/KRover.xcodeproj` in Xcode.
2. Open **Window → Devices and Simulators** (`Shift-Command-2`).
3. Select the connected iPhone (`i16P`).
4. Click **Take Screenshot**.
5. Xcode saves the PNG as `~/Desktop/Screenshot YYYY-MM-DD at HH.MM.SS.png`.

For the currently installed Xcode, the click can be automated with:

```sh
osascript <<'APPLESCRIPT'
tell application "Xcode" to activate
tell application "System Events"
  tell process "Xcode"
    set deviceWindows to every window whose name is "Devices"
    if (count of deviceWindows) is 0 then
      keystroke "2" using {command down, shift down}
      delay 3
    end if
    click button "Take Screenshot" of UI element 1 of UI element 7 of UI element 1 of window "Devices"
  end tell
end tell
APPLESCRIPT
```

Wait several seconds before selecting the newest matching PNG; Xcode writes it
asynchronously.

```sh
find "$HOME/Desktop" -maxdepth 1 -type f -name 'Screenshot *.png' -mmin -2 -print0 \
  | xargs -0 ls -1t | head -1
```

The UI-element indexes are specific to the present Xcode Devices window. If a
future Xcode changes the hierarchy, inspect the accessibility tree and locate
the button whose name is `Take Screenshot`.
