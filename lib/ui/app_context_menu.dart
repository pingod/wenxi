import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_popup_menu.dart';
import 'common.dart';

/// A Windows mouse menu. Touch and primary-button gestures stay with [child].
class AppContextMenu<T> extends StatefulWidget {
  const AppContextMenu({
    super.key,
    required this.actions,
    required this.onSelected,
    required this.child,
    this.enabled = true,
    this.identity,
  });

  final List<AppMenuAction<T>> Function() actions;
  final FutureOr<void> Function(T) onSelected;
  final Widget child;
  final bool enabled;

  /// Include the account, folder or selection when it affects the command target.
  final Object? identity;

  @override
  State<AppContextMenu<T>> createState() => _AppContextMenuState<T>();
}

class _AppContextMenuState<T> extends State<AppContextMenu<T>> {
  bool _open = false;

  Future<void> _show(TapUpDetails details) async {
    if (_open || !widget.enabled) return;
    final actions = widget.actions();
    if (actions.isEmpty) return;
    final identity = widget.identity;
    final route = ModalRoute.of(context);
    _open = true;
    try {
      final selected = await showAppContextMenu<T>(
        context: context,
        position: details.globalPosition,
        actions: actions,
      );
      if (!mounted ||
          !widget.enabled ||
          selected == null ||
          widget.identity != identity ||
          (route != null && !route.isCurrent)) {
        return;
      }
      // Tasks may complete, permissions may change, or a target may be removed
      // while the menu is open. Recheck before dispatching its command.
      if (widget.actions().any((a) => a.value == selected && a.enabled)) {
        await widget.onSelected(selected);
      }
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.windows && widget.enabled
      ? GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: _show,
          child: widget.child,
        )
      : widget.child;
}

Future<T?> showAppContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<AppMenuAction<T>> actions,
}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return showMenu<T>(
    context: context,
    requestFocus: true,
    positionBuilder: (context, constraints) {
      final overlay =
          Navigator.of(context).overlay!.context.findRenderObject()
              as RenderBox;
      final local = overlay.globalToLocal(position);
      return RelativeRect.fromRect(
        local & Size.zero,
        Offset.zero & overlay.size,
      );
    },
    color: dark ? const Color(0xff1c1c1e) : Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: border(context).withValues(alpha: .7)),
    ),
    clipBehavior: Clip.antiAlias,
    constraints: const BoxConstraints(minWidth: 208, maxWidth: 320),
    menuPadding: const EdgeInsets.symmetric(vertical: 6),
    items: [
      for (final action in actions)
        PopupMenuItem<T>(
          value: action.value,
          enabled: action.enabled,
          height: 40,
          child: Builder(
            builder: (context) {
              final color = !action.enabled
                  ? theme.disabledColor
                  : action.destructive
                  ? theme.colorScheme.error
                  : action.selected
                  ? themeAccent(context)
                  : theme.colorScheme.onSurface;
              return Semantics(
                selected: action.selected ? true : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(action.icon, size: 18, color: color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          action.label,
                          style: TextStyle(fontSize: 14, color: color),
                        ),
                      ),
                      if (action.detail != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          action.detail!,
                          style: TextStyle(fontSize: 12, color: color),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ],
  );
}
