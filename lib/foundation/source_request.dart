import 'dart:async';

/// Timeout bound for comic-source requests (loading comic info, page lists,
/// covers...).
///
/// Mirrors the per-attempt timeout used by the download pipeline
/// (`_runWithRetry` in `network/download.dart`, upstream issues #707, #799).
const Duration kSourceRequestTimeout = Duration(seconds: 30);

/// Runs [task] bounded by [timeout], turning a source request that never
/// completes into a [TimeoutException] instead of hanging the caller.
///
/// A JS source that hangs (network black hole, script deadlock) used to
/// freeze the caller forever; callers convert the exception into an error
/// state with a retry action (upstream issues #825, #742).
Future<T> runWithSourceTimeout<T>(Future<T> Function() task,
    {Duration timeout = kSourceRequestTimeout}) {
  return task().timeout(timeout);
}
