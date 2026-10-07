# Copy to projects.local.sh (gitignored) and edit paths.
# Sourced by run-dsh.sh resolve_project when present.
#
# Each alias prints one absolute directory path.

projects_resolve() {
  case "$1" in
    api)       printf '%s' "$HOME/Development/my-api" ;;
    android)   printf '%s' "$HOME/Development/my-android" ;;
    ios)       printf '%s' "$HOME/Development/my-ios" ;;
    app)       printf '%s' "$HOME/Development/my-app" ;;
    *)         return 1 ;;
  esac
}
