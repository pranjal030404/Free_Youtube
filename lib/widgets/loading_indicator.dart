import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Thin loading bar that listens to its own notifiers.
///
/// Keeping the frequent progress updates here means the rest of the screen
/// (and the WebView widget) is not rebuilt on every progress tick.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({
    super.key,
    required this.visible,
    required this.progress,
  });

  final ValueListenable<bool> visible;
  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: 3,
        child: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, isVisible, _) {
            if (!isVisible) return const SizedBox.shrink();
            return ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) =>
                  LinearProgressIndicator(value: value <= 0 ? null : value),
            );
          },
        ),
      ),
    );
  }
}
