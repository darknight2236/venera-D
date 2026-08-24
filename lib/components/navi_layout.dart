/// Layout visibility rules for [NaviPane], keyed by the animated navigation
/// mode value: `0/1` = narrow (bottom navigation bar), `2` = folded side
/// bar, `3` = expanded side bar (see `NaviPaneState.targetFormContext`).
///
/// Extracted from the widget tree so the rules are unit-testable.
class NaviLayout {
  /// Whether the main view shows its own top bar (current page label) and
  /// bottom navigation bar. Only in narrow mode; wider modes get a side bar
  /// instead.
  static bool showsTopAndBottomBars(double value) => value < 2;

  /// Opacity of the current-page label drawn at the top of the side bar.
  ///
  /// Fully opaque in folded mode (`value == 2`), fading out as the bar
  /// expands toward `value == 3`, where every nav item already carries its
  /// own label. Returns 0 everywhere else, hiding the label.
  ///
  /// The folded bar is icons-only and the narrow-mode top bar is gone, so
  /// without this label the current page title was rendered nowhere in
  /// landscape/folded mode (upstream issue #738).
  static double sidebarPageTitleOpacity(double value) {
    if (value < 2 || value >= 3) return 0;
    return 1 - (value - 2).clamp(0.0, 1.0);
  }
}
