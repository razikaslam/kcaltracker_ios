# KcalTrack native iOS project

This is a native SwiftUI rewrite of the supplied KcalTrack HTML app. It does **not** use WKWebView.

Features included:
- Supabase email/password sign-in and sign-up
- Cloud sync for profiles, food, workouts and weights through the `kcaltracker` schema
- Decimal kcal/macronutrient entry and display
- Home Day / Week / Month summaries
- Food history and add/delete
- Workout history and add/delete
- Profile targets and save
- iPhone/iPad responsive SwiftUI layout (including portrait and landscape)

## Build
Open `KcalTrackNative.xcodeproj` on a Mac with Xcode. Set your Apple Developer Team under the app target's Signing & Capabilities and build/run on your device.

The app uses the existing Supabase project and publishable key from the current KcalTrack HTML. No service-role key is included.
