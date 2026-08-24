/// Serializes asynchronous list reloads.
///
/// A page that reloads its data from a listener callback used to drop every
/// invalidation arriving while a load was in flight (`if (isLoading) return`),
/// so a change committed during the load window never reached the UI until
/// the user triggered another reload manually (upstream issue #768).
///
/// The gate coalesces those invalidations into a single pending re-run:
/// [beginLoad] returns false while a load is in flight (remembering the
/// invalidation), and [endLoad] reports whether a re-run is owed.
class ReloadGate {
  bool _loading = false;

  bool _pending = false;

  bool get isLoading => _loading;

  /// Attempts to start a load. Returns true when the caller may proceed;
  /// false when a load is already in flight, in which case the
  /// invalidation is remembered and folded into the pending re-run.
  bool beginLoad() {
    if (_loading) {
      _pending = true;
      return false;
    }
    _loading = true;
    return true;
  }

  /// Completes the in-flight load. Returns true when invalidations arrived
  /// during the load and the caller must immediately reload to pick them up.
  bool endLoad() {
    _loading = false;
    final rerun = _pending;
    _pending = false;
    return rerun;
  }
}
