import 'package:flutter/material.dart';

// ─── 品牌视觉 ───────────────────────────────────────────────────────────────

/// 品牌主渐变：蓝 → 靛紫（与应用主色 kAccent 呼应）。
const kBrandGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [Color(0xFF448AFF), Color(0xFF6A5BFF)],
);

/// 对话框圆角。
const kDialogRadius = 16.0;

/// 对话框柔和阴影（分层）。
const kDialogShadow = [
  BoxShadow(color: Color(0x1F000000), blurRadius: 28, offset: Offset(0, 10)),
  BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 3)),
];

// ─── 渐变圆底品牌图标 ───────────────────────────────────────────────────────

/// 渐变圆底白色图标：用于标题栏 logo、面板标题、列表选中项等品牌点缀。
class BrandIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  const BrandIcon({
    super.key,
    required this.icon,
    this.size = 22,
    this.iconSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: kBrandGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: iconSize, color: Colors.white),
    );
  }
}

// ─── 渐变填充按钮 ───────────────────────────────────────────────────────────

/// 渐变填充按钮：白字、圆角、hover 时阴影浮现、点击水波纹。
class GradientButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool expanded; // 占满父级宽度
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.expanded = false,
  });

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        decoration: BoxDecoration(
          gradient: kBrandGradient,
          borderRadius: BorderRadius.circular(10),
          boxShadow: _hovered
              ? const [
                  BoxShadow(
                      color: Color(0x40448AFF),
                      blurRadius: 14,
                      offset: Offset(0, 5)),
                ]
              : const [],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onPressed,
          splashColor: Colors.white.withValues(alpha: 0.25),
          highlightColor: Colors.white.withValues(alpha: 0.12),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(widget.label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: widget.expanded ? SizedBox(width: double.infinity, child: button) : button,
    );
  }
}

// ─── 现代化对话框 ───────────────────────────────────────────────────────────

/// 现代化对话框骨架：渐变头部横幅 + 白底内容 + 底部按钮区。
class ModernDialogFrame extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final double width;
  final List<Widget> children;
  final List<Widget> actions;

  const ModernDialogFrame({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.width = 380,
    required this.actions,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(kDialogRadius),
        boxShadow: kDialogShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 渐变头部横幅
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            decoration: const BoxDecoration(gradient: kBrandGradient),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 内容区
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
          // 底部按钮区
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: actions,
            ),
          ),
        ],
      ),
    );
  }
}

/// 以透明 [AlertDialog] 承载 [ModernDialogFrame] 弹出。
Future<T?> showModernDialog<T>(
  BuildContext context,
  Widget content,
) {
  return showDialog<T>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      contentPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kDialogRadius)),
      content: content,
    ),
  );
}
