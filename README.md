# Link Unlocker (Flutter)

Mobile app to resolve sfgl / sub4unlock / content-locker links: follows redirect chains and scrapes candidate final links.

## Build via GitHub Actions
1. Push this repo to GitHub.
2. Actions → "Build APK" runs automatically (or trigger manually).
3. Download artifact `link-unlocker-apk` → install APK.

## Local build
```bash
flutter pub get
flutter build apk --debug
```

## Token
If you need to push with a PAT: `git remote set-url origin https://<TOKEN>@github.com/<user>/<repo>.git`
