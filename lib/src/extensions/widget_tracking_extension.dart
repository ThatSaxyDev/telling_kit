import 'package:dartnative/dartnative.dart';

import '../telling.dart';
import '../models/log_event.dart';

/// Extension on Widget to enable automatic view tracking.
///
/// Ported from `telling_logger`. The Flutter original used
/// `package:flutter/widgets.dart`; the only real change is that import —
/// dartnative's `StatefulWidget`, `WidgetsBinding.addPostFrameCallback` and
/// `BuildContext` are Flutter-compatible, so the tracking semantics are
/// identical: the event fires on the first post-frame callback after mount,
/// not during build.
///
/// Usage:
/// ```dart
/// RaceDetailView().nowTelling(
///   name: 'Race Detail',
///   type: LogType.analytics,
/// )
/// ```
extension TellingWidgetExtension on Widget {
  /// Wraps this widget with automatic view tracking.
  ///
  /// Parameters:
  /// - [name]: Name of the view/widget (defaults to the widget's runtimeType)
  /// - [type]: Type of log event (defaults to [LogType.analytics])
  /// - [level]: Log level (defaults to [LogLevel.info])
  /// - [metadata]: Additional metadata to attach to the log
  /// - [trackOnce]: If true, only track the first mount (default: true)
  Widget nowTelling({
    String? name,
    LogType? type,
    LogLevel? level,
    Map<String, dynamic>? metadata,
    bool trackOnce = true,
  }) {
    return _TellingWrapper(
      name: name ?? runtimeType.toString(),
      type: type ?? LogType.analytics,
      level: level ?? LogLevel.info,
      metadata: metadata,
      trackOnce: trackOnce,
      child: this,
    );
  }
}

/// Internal wrapper widget that handles the view tracking.
class _TellingWrapper extends StatefulWidget {
  final String name;
  final LogType type;
  final LogLevel level;
  final Map<String, dynamic>? metadata;
  final bool trackOnce;
  final Widget child;

  const _TellingWrapper({
    required this.name,
    required this.type,
    required this.level,
    required this.metadata,
    required this.trackOnce,
    required this.child,
  });

  @override
  State<_TellingWrapper> createState() => _TellingWrapperState();
}

class _TellingWrapperState extends State<_TellingWrapper> {
  bool _hasTracked = false;

  @override
  void initState() {
    super.initState();
    _trackView();
  }

  @override
  void didUpdateWidget(_TellingWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Track again when trackOnce is off, or when the tracked name changed.
    if (!widget.trackOnce || oldWidget.name != widget.name) {
      _trackView();
    }
  }

  void _trackView() {
    if (widget.trackOnce && _hasTracked) return;

    // Fire after the frame is built, so the event reflects a mounted view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Telling.instance.log(
        'View: ${widget.name}',
        level: widget.level,
        type: widget.type,
        metadata: <String, dynamic>{
          'view_name': widget.name,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          ...?widget.metadata,
        },
      );

      _hasTracked = true;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
