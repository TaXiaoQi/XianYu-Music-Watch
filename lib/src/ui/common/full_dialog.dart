import 'package:flutter/material.dart';

import '../../core/watch_fit.dart';

Future<T?> showFullDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return Navigator.of(context, rootNavigator: true)
      .push(_FullDialogRoute<T>(builder: builder));
}

class _FullDialogRoute<T> extends PageRoute<T> {
  _FullDialogRoute({required this.builder});

  final WidgetBuilder builder;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildPage(context, animation, secondaryAnimation) =>
      builder(context);

  @override
  Widget buildTransitions(context, animation, secondaryAnimation, child) {
    final curved =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}

class FullDialogScaffold extends StatelessWidget {
  const FullDialogScaffold({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
  });

  final String? title;
  final Widget? content;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 16 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16 * s,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 14 * s),
                ],
                ?content,
                if (actions.isNotEmpty) ...[
                  SizedBox(height: 18 * s),
                  Row(
                    children: [
                      for (final (i, a) in actions.indexed) ...[
                        if (i > 0) SizedBox(width: 10 * s),
                        Expanded(child: a),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FullDialogButton extends StatelessWidget {
  const FullDialogButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;

  final bool primary;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: Size.fromHeight(42 * s),
        backgroundColor: primary
            ? const Color(0xFFFF4D6E)
            : Colors.white.withValues(alpha: 0.10),
        foregroundColor:
            primary ? Colors.white : Colors.white.withValues(alpha: 0.75),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(21 * s),
        ),
        textStyle: TextStyle(fontSize: 13.5 * s, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

Future<bool?> showFullConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String okLabel = '确定',
  String? cancelLabel = '取消',
  bool okOnly = false,
}) {
  final s = context.watchScale();
  return showFullDialog<bool>(
    context: context,
    builder: (context) => FullDialogScaffold(
      title: title,
      content: message == null
          ? null
          : Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5 * s,
                height: 1.6,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
      actions: [
        if (!okOnly)
          FullDialogButton(
            label: cancelLabel ?? '取消',
            onPressed: () => Navigator.pop(context),
          ),
        FullDialogButton(
          label: okLabel,
          primary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
}

Future<T?> showFullPicker<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  T? current,
}) {
  final s = context.watchScale();
  return showFullDialog<T>(
    context: context,
    builder: (context) => FullDialogScaffold(
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (value, label) in options)
            Padding(
              padding: EdgeInsets.only(bottom: 8 * s),
              child: _OptionButton(
                label: label,
                selected: value == current,
                onTap: () => Navigator.pop(context, value),
              ),
            ),
        ],
      ),
    ),
  );
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24 * s),
      child: Container(
        height: 48 * s,
        padding: EdgeInsets.symmetric(horizontal: 18 * s),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFFF4D6E).withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(24 * s),
          border: Border.all(
            color: selected
                ? const Color(0xFFFF4D6E)
                : Colors.white.withValues(alpha: 0.08),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5 * s,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? const Color(0xFFFF4D6E)
                      : Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded,
                  size: 18 * s, color: const Color(0xFFFF4D6E)),
          ],
        ),
      ),
    );
  }
}

Future<double?> showFullSlider(
  BuildContext context, {
  required String title,
  required double initial,
  required double min,
  required double max,
  required int divisions,
  required String Function(double) label,
  String? hint,
}) {
  return showFullDialog<double>(
    context: context,
    builder: (context) => _FullSliderPage(
      title: title,
      initial: initial,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      hint: hint,
    ),
  );
}

class _FullSliderPage extends StatefulWidget {
  const _FullSliderPage({
    required this.title,
    required this.initial,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    this.hint,
  });

  final String title;
  final double initial;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) label;
  final String? hint;

  @override
  State<_FullSliderPage> createState() => _FullSliderPageState();
}

class _FullSliderPageState extends State<_FullSliderPage> {
  late double _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return FullDialogScaffold(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label(_value),
            style: TextStyle(
              fontSize: 26 * s,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          if (widget.hint != null) ...[
            SizedBox(height: 4 * s),
            Text(
              widget.hint!,
              style: TextStyle(
                fontSize: 11 * s,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
          Slider(
            value: _value.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            activeColor: const Color(0xFFFF4D6E),
            onChanged: (v) => setState(() => _value = v),
          ),
        ],
      ),
      actions: [
        FullDialogButton(
          label: '取消',
          onPressed: () => Navigator.pop(context),
        ),
        FullDialogButton(
          label: '确定',
          primary: true,
          onPressed: () => Navigator.pop(context, _value),
        ),
      ],
    );
  }
}

Future<String?> showFullInput(
  BuildContext context, {
  required String title,
  required String hint,
  String okLabel = '确定',
  TextInputType? keyboardType,
}) {
  return showFullDialog<String>(
    context: context,
    builder: (context) => _FullInputPage(
      title: title,
      hint: hint,
      okLabel: okLabel,
      keyboardType: keyboardType,
    ),
  );
}

class _FullInputPage extends StatefulWidget {
  const _FullInputPage({
    required this.title,
    required this.hint,
    required this.okLabel,
    this.keyboardType,
  });

  final String title;
  final String hint;
  final String okLabel;
  final TextInputType? keyboardType;

  @override
  State<_FullInputPage> createState() => _FullInputPageState();
}

class _FullInputPageState extends State<_FullInputPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return FullDialogScaffold(
      title: widget.title,
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        style: TextStyle(fontSize: 13.5 * s, color: Colors.white),
        decoration: InputDecoration(
          hintText: widget.hint,
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.07),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12 * s),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      actions: [
        FullDialogButton(
          label: '取消',
          onPressed: () => Navigator.pop(context),
        ),
        FullDialogButton(
          label: widget.okLabel,
          primary: true,
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
        ),
      ],
    );
  }
}
