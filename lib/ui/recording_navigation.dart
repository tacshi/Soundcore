import 'package:flutter/material.dart';

import '../state/recording.dart';
import 'screens/recording_detail_screen.dart';

/// The shell owns navigation so recording shortcuts and row taps share a route.
class RecordingNavigation extends InheritedWidget {
  const RecordingNavigation({
    super.key,
    required this.onOpen,
    this.tabIndex = 0,
    required super.child,
  });

  final ValueChanged<RecordingReference> onOpen;
  final int tabIndex;

  static void open(BuildContext context, RecordingReference reference) {
    final navigation = context
        .dependOnInheritedWidgetOfExactType<RecordingNavigation>();
    if (navigation != null) {
      navigation.onOpen(reference);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordingDetailScreen(reference: reference),
        ),
      );
    }
  }

  @override
  bool updateShouldNotify(RecordingNavigation oldWidget) =>
      onOpen != oldWidget.onOpen || tabIndex != oldWidget.tabIndex;
}
