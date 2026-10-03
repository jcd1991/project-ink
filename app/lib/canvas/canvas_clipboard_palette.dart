import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum CanvasClipboardPaletteAction { copyBrushColor, pasteBrushColor }

/// Presents the color clipboard palette and runs the selected operation.
Future<void> showCanvasClipboardPalette({
  required BuildContext context,
  required bool Function() isMounted,
  required Color Function() activeColor,
  required Future<void> Function(Color color) applyPastedColor,
}) async {
  if (!isMounted()) return;
  final action = await showModalBottomSheet<CanvasClipboardPaletteAction>(
    context: context,
    builder: (_) => const CanvasClipboardPalette(),
  );
  if (!isMounted() || action == null) return;
  if (action == CanvasClipboardPaletteAction.copyBrushColor) {
    await CanvasColorClipboard.copy(activeColor());
    return;
  }
  final color = await CanvasColorClipboard.paste();
  if (color != null) await applyPastedColor(color);
}

/// Small command sheet for copying or pasting the active brush color.
class CanvasClipboardPalette extends StatelessWidget {
  const CanvasClipboardPalette({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Wrap(
      children: [
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Copy brush color'),
          onTap:
              () => Navigator.of(
                context,
              ).pop(CanvasClipboardPaletteAction.copyBrushColor),
        ),
        ListTile(
          leading: const Icon(Icons.content_paste),
          title: const Text('Paste brush color'),
          onTap:
              () => Navigator.of(
                context,
              ).pop(CanvasClipboardPaletteAction.pasteBrushColor),
        ),
      ],
    ),
  );
}

/// Clipboard access and the plain six-digit RGB text representation.
abstract final class CanvasColorClipboard {
  static final _rgbHex = RegExp(r'^#?([0-9a-fA-F]{6})$');

  static String encode(Color color) =>
      '#${(color.r * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(color.g * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(color.b * 255).round().toRadixString(16).padLeft(2, '0')}';

  static Color? decode(String? text) {
    final match = _rgbHex.firstMatch(text?.trim() ?? '');
    if (match == null) return null;
    final value = int.parse(match.group(1)!, radix: 16);
    return Color(0xff000000 | value);
  }

  static Future<void> copy(Color color) =>
      Clipboard.setData(ClipboardData(text: encode(color)));

  static Future<Color?> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return decode(data?.text);
  }
}
