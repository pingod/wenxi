import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'common.dart';

class AppMenuAction<T> {
  const AppMenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
    this.detail,
  });

  final T value;
  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final bool destructive;
  final String? detail;
}

class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.actions,
    required this.onSelected,
    this.label,
  });

  final String tooltip;
  final IconData icon;
  final List<AppMenuAction<T>> actions;
  final ValueChanged<T> onSelected;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      color: dark ? const Color(0xff1c1c1e) : Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: dark ? .3 : .12),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border(context).withValues(alpha: .7)),
      ),
      clipBehavior: Clip.antiAlias,
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 320),
      menuPadding: const EdgeInsets.all(6),
      icon: label != null
          ? null
          : Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: themeAccent(context).withValues(alpha: dark ? .14 : .07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: themeAccent(context), size: 21),
            ),
      child: label == null
          ? null
          : Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              decoration: BoxDecoration(
                color: themeAccent(context).withValues(alpha: dark ? .14 : .07),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: themeAccent(context), size: 20),
                  const SizedBox(width: 5),
                  Text(
                    label!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: themeAccent(context),
                    ),
                  ),
                ],
              ),
            ),
      itemBuilder: (context) => [
        for (final action in actions)
          PopupMenuItem<T>(
            value: action.value,
            enabled: action.enabled,
            padding: EdgeInsets.zero,
            child: Semantics(
              selected: action.selected ? true : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: action.selected
                      ? themeAccent(context).withValues(alpha: dark ? .16 : .07)
                      : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: themeAccent(
                          context,
                        ).withValues(alpha: dark ? .14 : .08),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        action.icon,
                        color: themeAccent(context),
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        action.label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: action.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: action.selected
                              ? themeAccent(context)
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (action.detail != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        action.detail!,
                        style: TextStyle(
                          fontSize: 12,
                          color: themeAccent(context),
                        ),
                      ),
                    ],
                    if (action.selected) ...[
                      const SizedBox(width: 8),
                      Icon(
                        CupertinoIcons.checkmark,
                        color: themeAccent(context),
                        size: 16,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
