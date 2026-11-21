import 'package:flutter/widgets.dart';

/// Spy widget for counting build invocations to verify zero widget rebuild churn.
class BuildCounterSpy extends StatefulWidget {
  final Widget? child;
  final Widget Function(BuildContext context, int count)? builder;
  final VoidCallback? onRebuild;

  const BuildCounterSpy({
    super.key,
    this.child,
    this.builder,
    this.onRebuild,
  }) : assert(child != null || builder != null, 'Either child or builder must be provided');

  @override
  BuildCounterSpyState createState() => BuildCounterSpyState();
}

class BuildCounterSpyState extends State<BuildCounterSpy> {
  int _buildCount = 0;

  int get buildCount => _buildCount;

  void reset() {
    _buildCount = 0;
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    widget.onRebuild?.call();
    if (widget.builder != null) {
      return widget.builder!(context, _buildCount);
    }
    return widget.child!;
  }
}
