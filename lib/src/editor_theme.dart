import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/styles/a11y-light.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/intellij-light.dart';

// ─── 颜色常量 ───────────────────────────────────────────────────────────────

/// 应用整体背景
const kBg = Color(0xFFF5F5F5);
/// 左侧编辑区背景
const kEditorBg = Color(0xFFFAFAFA);
/// 行号栏背景
const kEditorPanelBg = Color(0xFFF7F8FA);
/// 右侧预览区背景
const kPreviewBg = Colors.white;
const kBorder = Color(0xFFE0E0E0);
const kTextPrimary = Color(0xFF1F1F1F);
const kTextSecondary = Color(0xFF8A9099);
const kAccent = Color(0xFF448AFF);

// ─── 字体 ───────────────────────────────────────────────────────────────────

/// 编辑区等宽字体：JetBrains Mono / Cascadia Code / Consolas / monospace。
/// 中文通过 fallback 落到 Microsoft YaHei。
const kEditorFontFamily = 'Cascadia Code';
const kEditorFontFallback = <String>[
  'JetBrains Mono',
  'Consolas',
  'monospace',
  'Microsoft YaHei',
];

// ─── Markdown 语法高亮主题 ────────────────────────────────────────────────

/// 可在设置中切换的浅色高亮主题。
const kHighlightThemeNames = <String, String>{
  'GitHub Light': 'github',
  'IntelliJ Light': 'intellij',
  'A11Y Light': 'a11y',
};

Map<String, TextStyle> baseHighlightTheme(String key) {
  switch (key) {
    case 'intellij':
      return intellijLightTheme;
    case 'a11y':
      return a11YLightTheme;
    case 'github':
    default:
      return githubTheme;
  }
}

/// 基于 highlight.js 浅色主题定制，区分文档结构：
/// 标题深蓝加粗、标记符号浅灰、URL 蓝色下划线、代码块独立浅灰背景、
/// 注释/引用灰、加粗/斜体保留语义。
Map<String, TextStyle> buildMarkdownTheme({String base = 'github'}) {
  final theme = Map<String, TextStyle>.from(baseHighlightTheme(base));
  theme['root'] = const TextStyle(color: Color(0xFF24292E));
  // 标题（# 到 ####### 统一 section scope）
  theme['section'] = const TextStyle(
    color: Color(0xFF1565C0),
    fontWeight: FontWeight.w700,
  );
  // 列表符号、区块标记
  theme['bullet'] = const TextStyle(color: Color(0xFFB0B7C3));
  theme['meta'] = const TextStyle(color: Color(0xFFB0B7C3));
  // URL
  theme['link'] = const TextStyle(
    color: Color(0xFF1565C0),
    decoration: TextDecoration.underline,
  );
  // 链接文本等
  theme['string'] = const TextStyle(color: Color(0xFF0550AE));
  // 代码块 / 内联代码：整块独立浅灰背景
  theme['code'] = const TextStyle(
    color: Color(0xFF24292E),
    backgroundColor: Color(0xFFF0F2F5),
    fontFamily: kEditorFontFamily,
    fontFamilyFallback: kEditorFontFallback,
  );
  theme['strong'] = const TextStyle(
    color: Color(0xFF1F1F1F),
    fontWeight: FontWeight.w700,
  );
  theme['emphasis'] = const TextStyle(
    color: Color(0xFF1F1F1F),
    fontStyle: FontStyle.italic,
  );
  theme['quote'] = const TextStyle(color: Color(0xFF6A737D));
  theme['comment'] = const TextStyle(color: Color(0xFF8A9199));
  theme['symbol'] = const TextStyle(color: Color(0xFFE36209));
  return theme;
}

/// 编辑区使用的语法高亮规则：Markdown。
CodeHighlightTheme buildMarkdownCodeTheme({String base = 'github'}) {
  return CodeHighlightTheme(
    languages: {
      'markdown': CodeHighlightThemeMode(mode: langMarkdown),
    },
    theme: buildMarkdownTheme(base: base),
  );
}
