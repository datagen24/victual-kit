/// Observable stores over ``VictualCore``'s client, shared by every
/// Apple-platform front end.
///
/// ## What belongs here
///
/// State a screen observes, and the work that produces it: fetching, caching,
/// filtering, sorting, deciding when to refresh, and turning a
/// `VictualError` into something a view can render. Types here are
/// `@MainActor @Observable`, matching `VictualSession`.
///
/// ## What does not
///
/// Views, and anything that only compiles on one platform. This target is built
/// for every platform the package supports, and a future iOS front end reuses
/// it unchanged — which is also why it is separate from `VictualUI`, whose job
/// is the connection itself rather than what a connection is used for.
///
/// Request and response mapping does not belong here either. That lives in
/// `VictualCore`, so the boundary where generated symbols stop being visible is
/// one layer lower and a specification re-sync breaks one file rather than
/// many.
///
/// See `docs/plans/01-macos-stock-app.md`.
public enum VictualStock {}
