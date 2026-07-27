part of 'components.dart';

const _fastAnimationDuration = Duration(milliseconds: 160);

/// Corner radius tokens. Keep every rounded corner on this scale.
///
/// Use [full] for pills, capsules and circular clips instead of an
/// arbitrary oversized value; Flutter clamps it to half of the shortest
/// side, so the shape stays round at any size.
abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 999;
}

/// Spacing tokens for paddings, margins and gaps.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}