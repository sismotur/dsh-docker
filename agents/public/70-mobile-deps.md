## iOS and Android dependency management

- **iOS (CocoaPods):** when the project uses CocoaPods (`Podfile`/`Pods/`),
  always use `pod install` and `pod update`. Never Swift Package Manager for
  that tree.
- **Android (Gradle Kotlin DSL):** when the project uses `build.gradle.kts`,
  always use the Gradle wrapper (`./gradlew`) instead of a global `gradle`
  command.
