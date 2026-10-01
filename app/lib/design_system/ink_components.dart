import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'ink_theme.dart';

InkColors inkColors(BuildContext context) =>
    Theme.of(context).extension<InkColors>() ??
    (Theme.of(context).brightness == Brightness.dark
        ? InkTheme.dark().extension<InkColors>()!
        : InkTheme.light().extension<InkColors>()!);

InkMetrics inkMetrics(BuildContext context) =>
    Theme.of(context).extension<InkMetrics>() ?? const InkMetrics();

enum InkProjectIconId { brush, ruler, panel, vector, mask, tone }

class InkProjectIcon extends StatelessWidget {
  const InkProjectIcon(this.id, {super.key, this.size = 20, this.color});

  final InkProjectIconId id;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final names = <InkProjectIconId, String>{
      InkProjectIconId.brush: 'brush',
      InkProjectIconId.ruler: 'ruler',
      InkProjectIconId.panel: 'panel',
      InkProjectIconId.vector: 'vector',
      InkProjectIconId.mask: 'mask',
      InkProjectIconId.tone: 'tone',
    };
    return SvgPicture.asset(
      'assets/icons/${names[id]}.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        color ?? IconTheme.of(context).color ?? Colors.white,
        BlendMode.srcIn,
      ),
      semanticsLabel: id.name,
    );
  }
}

class InkPanelSurface extends StatelessWidget {
  const InkPanelSurface({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    final metrics = inkMetrics(context);
    return Material(
      color: colors.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.panelBorder),
        borderRadius: BorderRadius.circular(metrics.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? EdgeInsets.all(metrics.grid * 3),
        child: child,
      ),
    );
  }
}

class InkDockHeader extends StatelessWidget {
  const InkDockHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: inkColors(context).panelRaised,
        border: Border(
          bottom: BorderSide(color: inkColors(context).panelBorder),
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: largeText ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: largeText ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class InkToolButton extends StatelessWidget {
  const InkToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    final metrics = inkMetrics(context);
    final height =
        compact ? metrics.desktopControlHeight : metrics.touchControlHeight;
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? colors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height, minWidth: height),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: compact ? 18 : 22,
                      color: selected ? colors.toolActive : null,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(label, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared icon-only command control for toolbars, launchers, and inspectors.
///
/// Flutter's [IconButton] supplies the pressed, hovered, focus, and disabled
/// visuals; this wrapper standardizes command naming, selection semantics, and
/// the minimum hit target across editor surfaces.
class InkCommandButton extends StatelessWidget {
  const InkCommandButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.hitSize = 40,
    this.iconSize = 18,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double hitSize;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: label,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.standard,
          constraints: BoxConstraints.tightFor(width: hitSize, height: hitSize),
          onPressed: onPressed,
          color: selected ? inkColors(context).selectedStrong : null,
          iconSize: iconSize,
          icon: Icon(icon),
        ),
      ),
    ),
  );
}

/// Consistent labeled action for editor dialogs. Unlike [InkCommandButton],
/// this control keeps its label visible instead of relying on a tooltip.
class InkDialogAction extends StatelessWidget {
  const InkDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final minimumHeight =
        math.max(inkMetrics(context).touchControlHeight, 48).toDouble();
    final size = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(88, minimumHeight)),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumHeight),
      child:
          primary
              ? FilledButton(
                onPressed: onPressed,
                style: size,
                child: Text(label),
              )
              : TextButton(
                onPressed: onPressed,
                style: size,
                child: Text(label),
              ),
    );
  }
}

/// Tokenized selectable control for brush presets, tags, and compact filters.
/// The whole pill remains a clearly labeled keyboard/pointer target.
class InkSelectableChip extends StatelessWidget {
  const InkSelectableChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.leading,
    this.minimumHeight = 48,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final Widget? leading;
  final double minimumHeight;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: label,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minimumHeight),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? colors.selected : colors.panelRaised,
                  border: Border.all(
                    color:
                        selected ? colors.selectedStrong : colors.panelBorder,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (leading != null) ...[
                        IconTheme(
                          data: IconThemeData(
                            size: 16,
                            color: selected ? colors.selectedStrong : null,
                          ),
                          child: leading!,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact, selectable row for the layer inspector.
///
/// The row keeps its artwork identity and title readable while leaving the
/// caller in control of layer-specific controls and pointer gestures.
class InkLayerRow extends StatelessWidget {
  const InkLayerRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onLongPress,
    this.minimumHeight = 48,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double minimumHeight;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    final metrics = inkMetrics(context);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final effectiveMinimumHeight = math.max(
      minimumHeight,
      metrics.touchControlHeight,
    );
    return Semantics(
      selected: selected,
      child: Material(
        color:
            selected
                ? colors.selected.withValues(alpha: 0.48)
                : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: effectiveMinimumHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 8)],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DefaultTextStyle(
                          style: Theme.of(context).textTheme.bodyMedium!,
                          maxLines: largeText ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          child: title,
                        ),
                        if (subtitle != null)
                          DefaultTextStyle(
                            style: Theme.of(context).textTheme.bodySmall!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            child: subtitle!,
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 4),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InkInspectorSection extends StatelessWidget {
  const InkInspectorSection({
    super.key,
    required this.title,
    required this.child,
    this.leading,
    this.subtitle,
    this.initiallyExpanded = true,
  });

  final String title;
  final Widget child;
  final Widget? leading;
  final String? subtitle;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    return Theme(
      data: Theme.of(
        context,
      ).copyWith(dividerColor: inkColors(context).panelBorder),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: leading,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title:
              subtitle == null
                  ? Text(title, style: Theme.of(context).textTheme.labelLarge)
                  : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: largeText ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      Text(
                        subtitle!,
                        maxLines: largeText ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
          children: [child],
        ),
      ),
    );
  }
}

/// Theme-aligned compact row for inspector settings, materials, and metadata.
/// It stays desktop-dense while preserving a 48px target on narrow/touch
/// layouts and bounds long text without removing its accessible label.
class InkInspectorRow extends StatelessWidget {
  const InkInspectorRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.selected = false,
  });

  final String title;
  final String? subtitle;
  final Widget? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    final rowHeight = narrow ? 48.0 : 40.0;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? colors.selected : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: rowHeight),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.panelBorder.withValues(alpha: 0.7),
                ),
              ),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  SizedBox(width: 28, child: Center(child: icon)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: largeText ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: trailing!,
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

/// Shared toggle pill for independent layer states such as alpha lock and
/// clipping. It keeps desktop density while retaining touch-safe hit regions.
class InkToggleChip extends StatelessWidget {
  const InkToggleChip({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.icon,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = inkColors(context);
    final minimumHeight =
        MediaQuery.sizeOf(context).width < 720
            ? inkMetrics(context).touchControlHeight
            : math.max(40, inkMetrics(context).desktopControlHeight).toDouble();
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: value,
      label: label,
      onTap: enabled ? () => onChanged(!value) : null,
      child: ExcludeSemantics(
        child: Material(
          color:
              value
                  ? colors.selected
                  : (enabled ? colors.panelRaised : colors.panel),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: enabled ? () => onChanged(!value) : null,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minimumHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 16),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable palette/menu row with consistent typography and accessible action
/// semantics. Use compact rows in docks and touch rows in sheets.
class InkMenuItem extends StatelessWidget {
  const InkMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.subtitle,
    this.trailing,
    this.destructive = false,
    this.compact = false,
  });

  final String label;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool destructive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final minHeight =
        compact
            ? math.max(40, inkMetrics(context).desktopControlHeight).toDouble()
            : inkMetrics(context).touchControlHeight;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      hint: subtitle,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        size: 18,
                        color:
                            destructive
                                ? Theme.of(context).colorScheme.error
                                : null,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  destructive
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class InkPropertySlider extends StatelessWidget {
  const InkPropertySlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.divisions,
    this.valueLabel,
    this.valueWidth = 72,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String? valueLabel;
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final displayedValue = valueLabel ?? value.toStringAsFixed(0);
    final slider = Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    return Semantics(
      label: label,
      value: displayedValue,
      child:
          scaler.scale(14) > 18
              ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(label)),
                      const SizedBox(width: 8),
                      Text(displayedValue, textAlign: TextAlign.end),
                    ],
                  ),
                  slider,
                ],
              )
              : Row(
                children: [
                  SizedBox(width: 76, child: Text(label)),
                  Expanded(child: slider),
                  SizedBox(
                    width: valueWidth,
                    child: Text(
                      displayedValue,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
    );
  }
}

class InkStatusChip extends StatelessWidget {
  const InkStatusChip({super.key, required this.label, this.icon, this.tone});

  final String label;
  final IconData? icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: (tone ?? inkColors(context).selected).withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: tone ?? inkColors(context).panelBorder),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 4)],
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}
