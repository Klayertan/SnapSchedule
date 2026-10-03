# SnapSchedule

A Mac, iPhone and iPad app that turns a screenshot, photo or PDF of a schedule into Apple Calendar events.

- `SnapSchedule.xcodeproj`, `SnapSchedule/`, `Config/` — the app (SwiftUI, Xcode 26 or later). Open the project, pick your Team under Signing & Capabilities, and run.
- `training/` — a kit for testing and fine-tuning a local model that reads timetables. Start with `training/README.md`; Step 0 needs only a Mac with Ollama.

The app reads simple pictures on-device with Apple Intelligence. Big timetables need an AI server, set in the app's Settings: a local model through Ollama, Sakura AI Engine, or Claude.
