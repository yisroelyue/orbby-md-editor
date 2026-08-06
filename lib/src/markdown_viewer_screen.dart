import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_editor/re_editor.dart';
import 'package:screen_retriever/screen_retriever.dart';

import 'editor_theme.dart';
import 'mermaid_view.dart';
import 'package:window_manager/window_manager.dart';

// ─── 主内容组件 ─────────────────────────────────────────────────────────────

class MarkdownViewerScreen extends StatefulWidget {
  const MarkdownViewerScreen({super.key});

  @override
  State<MarkdownViewerScreen> createState() => MarkdownViewerScreenState();
}

class MarkdownViewerScreenState extends State<MarkdownViewerScreen> {
  final _controller = CodeLineEditingController();
  final _editorScrollController = CodeScrollController();
  final _previewScrollController = ScrollController();
  final _editorFocusNode = FocusNode();

  double _dividerPosition = 0.46;
  bool _isDragging = false;
  bool _isMaximized = false;
  Rect _restoreBounds = const Rect.fromLTWH(0, 0, 1400, 1000);
  String? _currentFilePath;

  // 编辑器设置（可在设置弹窗中调整）
  double _editorFontSize = 14;
  double _editorLineHeight = 1.8;
  String _highlightTheme = 'github';

  // 保存状态：记录最后一次保存时的文本，用于 dirty 判断
  String _savedBaseline = '';

  @override
  void initState() {
    super.initState();
    _savedBaseline = _controller.text;
    _controller.addListener(_onEditorChanged);
    // 直接监听全局键盘，确保 Ctrl+S 在编辑器聚焦时也能触发保存
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _controller.removeListener(_onEditorChanged);
    _controller.dispose();
    _editorScrollController.dispose();
    _previewScrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  // re_editor 的 controller 可能在 build/layout 阶段派发通知（如选区修复、
  // 中文输入法 composing），此时同步 setState 会抛 "setState during build"。
  // 统一推迟到帧结束，并保证同一帧只刷新一次。
  bool _editorUpdateScheduled = false;

  void _onEditorChanged() {
    if (!mounted || _editorUpdateScheduled) return;
    _editorUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editorUpdateScheduled = false;
      if (mounted) setState(() {});
    });
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyS &&
        HardwareKeyboard.instance.isControlPressed) {
      _saveFile();
      return true;
    }
    return false;
  }

  String get _rawMarkdown => _controller.text;
  int get _charCount => _controller.text.length;
  int get _lineCount => _controller.lineCount;
  bool get _isDirty => _controller.text != _savedBaseline;
  int get _mermaidBlocks => '```mermaid'.allMatches(_controller.text).length;

  /// 当前光标行列（0-based）
  (int, int) get _cursorPos {
    final sel = _controller.selection;
    return (sel.baseIndex, sel.baseOffset);
  }

  // ── 文本编辑工具 ──────────────────────────────────────────────────────

  /// 全局字符偏移 → (行, 列)
  (int, int) _rowColOf(int offset) {
    final text = _controller.text;
    final len = text.length;
    int row = 0, col = 0;
    for (int i = 0; i < offset && i < len; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        row++;
        col = 0;
      } else {
        col++;
      }
    }
    return (row, col);
  }

  /// 行的起始全局字符偏移
  int _lineStartOffset(int row) {
    final text = _controller.text;
    int offset = 0;
    for (int i = 0; i < row; i++) {
      final next = text.indexOf('\n', offset);
      if (next == -1) return text.length;
      offset = next + 1;
    }
    return offset;
  }

  /// 行的结束全局字符偏移（不含换行符）
  int _lineEndOffset(int lineStart) {
    final idx = _controller.text.indexOf('\n', lineStart);
    return idx == -1 ? _controller.text.length : idx;
  }

  void _setCaretAt(int offset) {
    final (row, col) = _rowColOf(offset);
    _controller.selection = CodeLineSelection.fromPosition(
      position: CodeLinePosition(index: row, offset: col),
    );
  }

  /// 用 before/after 包裹当前选区；无选区时插入占位文字并把光标落在其后。
  ///
  /// 兼容标题：若选区从标题行的 `#` 前缀内/行首开始，自动把起始点移到前缀
  /// 之后，只包裹标题文字，得到 `## **文字**` 这类合法 markdown，
  /// 避免加粗操作把标题格式破坏掉。
  void _wrapSelection(String before, String after, {String placeholder = '文本'}) {
    final sel = _controller.selection;
    var lo = _lineStartOffset(sel.baseIndex) + sel.baseOffset;
    var hi = _lineStartOffset(sel.extentIndex) + sel.extentOffset;
    if (lo > hi) {
      final t = lo;
      lo = hi;
      hi = t;
    }
    // 标题前缀兼容
    final lineStart = _lineStartOffset(_rowColOf(lo).$1);
    final lineText =
        _controller.text.substring(lineStart, _lineEndOffset(lineStart));
    final m = RegExp(r'^#+\s*').firstMatch(lineText);
    if (m != null && lineStart + m.end >= lo) {
      lo = lineStart + m.end;
      if (hi < lo) hi = lo;
    }
    final selected = _controller.text.substring(lo, hi);
    final content = selected.trim().isEmpty ? placeholder : selected;
    final newText =
        _controller.text.replaceRange(lo, hi, '$before$content$after');
    _controller.text = newText;
    _setCaretAt(lo + before.length + content.length);
  }

  void _insertBold() => _wrapSelection('**', '**', placeholder: '加粗');
  void _insertItalic() => _wrapSelection('*', '*', placeholder: '斜体');
  void _insertCode() => _wrapSelection('`', '`', placeholder: '代码');
  void _insertLink() => _wrapSelection('[', '](https://)', placeholder: '链接文字');

  void _insertHeading(int level) {
    final row = _controller.selection.baseIndex;
    final lineStart = _lineStartOffset(row);
    final text = _controller.text;
    final lineEnd = text.indexOf('\n', lineStart);
    final end = lineEnd == -1 ? text.length : lineEnd;
    final line = text.substring(lineStart, end);
    // 替换行首已存在的 # 前缀
    final trimmed = line.replaceFirst(RegExp(r'^#+\s*'), '');
    final newLine = '${'#' * level} $trimmed';
    final newText = text.replaceRange(lineStart, end, newLine);
    _controller.text = newText;
    _setCaretAt(lineStart + newLine.length);
  }

  void _insertTable() {
    final sel = _controller.selection;
    final offset = _lineStartOffset(sel.baseIndex) + sel.baseOffset;
    const table = '| 列 1 | 列 2 |\n| --- | --- |\n|  |  |';
    final text = _controller.text;
    _controller.text = text.replaceRange(offset, offset, table);
    _setCaretAt(offset + '| 列 1 | 列 2 |\n| --- | --- |\n| '.length);
  }

  // ── 文件操作 ───────────────────────────────────────────────────────────

  Future<void> _openFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.first.path;
    if (filePath == null) return;

    try {
      final content = await File(filePath).readAsString();
      _controller.text = content;
      _currentFilePath = filePath;
      _savedBaseline = content;
      if (mounted) {
        _showSnackBar('已加载: ${result.files.first.name}');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('读取文件失败: $e', error: true);
      }
    }
  }

  Future<void> _saveFile() async {
    String? savePath = _currentFilePath;
    savePath ??= await FilePicker.platform.saveFile(
      dialogTitle: '保存 Markdown 文件',
      fileName: 'output.md',
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'txt'],
    );
    if (savePath == null) return;

    try {
      await File(savePath).writeAsString(_controller.text);
      _currentFilePath = savePath;
      _savedBaseline = _controller.text;
      if (mounted) setState(() {});
      if (mounted) {
        final name = savePath.split(Platform.pathSeparator).last;
        _showSnackBar('已保存: $name');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('保存失败: $e', error: true);
      }
    }
  }

  void _showSnackBar(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          backgroundColor: error ? Colors.red.shade800 : const Color(0xFF333333),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ── 窗口最大化 ─────────────────────────────────────────────────────────

  /// 无边框窗口最大化时手动铺满屏幕可见区（工作区），避免盖住任务栏。
  Future<void> _toggleMaximize() async {
    if (_isMaximized) {
      await windowManager.setBounds(_restoreBounds);
    } else {
      _restoreBounds = await windowManager.getBounds();
      final display = await screenRetriever.getPrimaryDisplay();
      final pos = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      // 铺满工作区（已排除任务栏），无边框窗口避免盖住状态栏
      await windowManager.setBounds(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height));
    }
    if (mounted) setState(() => _isMaximized = !_isMaximized);
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        colorSchemeSeed: kAccent,
        brightness: Brightness.light,
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei',
      ),
      child: Scaffold(
        backgroundColor: kBg,
        body: Column(
          children: [
            _buildTitleBar(),
            _buildToolbar(),
            _buildFormatBar(),
            Expanded(child: _buildSplitView()),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  // ── 标题栏 ─────────────────────────────────────────────────────────────

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: kPreviewBg,
          border: Border(bottom: BorderSide(color: kBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 4),
            SvgPicture.asset('assets/markdown.svg',
                width: 18, height: 18),
            const SizedBox(width: 8),
            const Text('OrbbyMDEditor',
                style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none)),
            const Spacer(),
            _TitleBarBtn(
                icon: Icons.minimize_rounded,
                onTap: () => windowManager.minimize()),
            const SizedBox(width: 4),
            _TitleBarBtn(
                icon: _isMaximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                onTap: _toggleMaximize),
            const SizedBox(width: 4),
            _TitleBarBtn(
                icon: Icons.close_rounded, onTap: () => windowManager.destroy()),
          ],
        ),
      ),
    );
  }

  // ── 工具栏 ─────────────────────────────────────────────────────────────

  /// 第一行：文件操作栏 —— 文件名 + 打开/保存/设置
  Widget _buildToolbar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kPreviewBg,
        border: Border(bottom: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          _IconBtn(
              icon: Icons.folder_open_rounded,
              tooltip: '打开文件',
              onTap: _openFile),
          const SizedBox(width: 4),
          _IconBtn(
              icon: Icons.save_rounded,
              tooltip: '保存',
              onTap: _saveFile),
          const SizedBox(width: 6),
          _IconBtn(
              icon: Icons.settings_rounded,
              tooltip: '设置',
              onTap: _showSettings),
          _toolbarSeparator(),
          _buildFileName(),
        ],
      ),
    );
  }

  /// 第二行：文本格式栏 —— Markdown 快捷操作 + 撤销/重做 + 字数
  Widget _buildFormatBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kPreviewBg,
        border: Border(bottom: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          _IconBtn(
              icon: Icons.format_bold_rounded,
              tooltip: '粗体',
              onTap: _insertBold),
          _IconBtn(
              icon: Icons.format_italic_rounded,
              tooltip: '斜体',
              onTap: _insertItalic),
          _HeadingMenu(onSelected: _insertHeading),
          _IconBtn(
              icon: Icons.link_rounded,
              tooltip: '链接',
              onTap: _insertLink),
          _IconBtn(
              icon: Icons.code_rounded,
              tooltip: '行内代码',
              onTap: _insertCode),
          _IconBtn(
              icon: Icons.table_chart_rounded,
              tooltip: '表格',
              onTap: _insertTable),
          _toolbarSeparator(),
          // 撤销 / 重做
          _IconBtn(
              icon: Icons.undo_rounded,
              tooltip: '撤销',
              onTap: _controller.undo,
              enabled: _controller.canUndo),
          _IconBtn(
              icon: Icons.redo_rounded,
              tooltip: '重做',
              onTap: _controller.redo,
              enabled: _controller.canRedo),
          const Spacer(),
          Text('字数 $_charCount',
              style: const TextStyle(fontSize: 12, color: kTextSecondary)),
        ],
      ),
    );
  }

  Widget _toolbarSeparator() {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: kBorder,
    );
  }

  Widget _buildFileName() {
    final base = _currentFilePath == null
        ? '未命名'
        : _currentFilePath!.split(Platform.pathSeparator).last;
    // 去掉已有扩展名，统一以 .markdown 结尾
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final name = '$stem.markdown';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 未保存标记
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: _isDirty ? kAccent : Colors.transparent,
            shape: BoxShape.circle,
          ),
        ),
        Text(name,
            style: const TextStyle(
                color: kTextPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ── 分割视图 ───────────────────────────────────────────────────────────

  Widget _buildSplitView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const dividerWidth = 4.0;
        final leftWidth = (totalWidth - dividerWidth) * _dividerPosition;

        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: leftWidth,
              child: _buildEditorPanel(),
            ),
            Positioned(
              left: leftWidth,
              top: 0,
              bottom: 0,
              width: dividerWidth,
              child: _buildDivider(totalWidth),
            ),
            Positioned(
              left: leftWidth + dividerWidth,
              top: 0,
              bottom: 0,
              right: 0,
              child: _buildPreviewPanel(),
            ),
            // 拖拽时的宽度提示
            if (_isDragging)
              Positioned(
                left: leftWidth + dividerWidth / 2 - 24,
                top: 16,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('${(_dividerPosition * 100).round()}%',
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
          ],
        );
      },
    );
  }

  // ── 左侧编辑面板 ───────────────────────────────────────────────────────

  Widget _buildEditorPanel() {
    return Container(
      color: kEditorBg,
      child: CodeEditor(
        controller: _controller,
        scrollController: _editorScrollController,
        focusNode: _editorFocusNode,
        autofocus: true,
        wordWrap: false,
        style: CodeEditorStyle(
          fontSize: _editorFontSize,
          fontFamily: kEditorFontFamily,
          fontFamilyFallback: kEditorFontFallback,
          fontHeight: _editorLineHeight,
          textColor: kTextPrimary,
          hintTextColor: kTextSecondary.withValues(alpha: 0.7),
          backgroundColor: kEditorBg,
          cursorColor: kAccent,
          cursorWidth: 2,
          // 当前行上下描边线（浅灰）
          cursorLineColor: const Color(0xFFECECEC),
          selectionColor: kAccent.withValues(alpha: 0.22),
          codeTheme: buildMarkdownCodeTheme(base: _highlightTheme),
        ),
        padding: const EdgeInsets.only(left: 24, right: 24, top: 16, bottom: 80),
        hint: '在此输入 Markdown 内容...',
        indicatorBuilder: _buildLineNumber,
        scrollbarBuilder: _buildScrollbar,
        verticalScrollbarWidth: 8,
        horizontalScrollbarHeight: 8,
      ),
    );
  }

  // ── 行号栏 ─────────────────────────────────────────────────────────────

  Widget _buildLineNumber(
    BuildContext context,
    CodeLineEditingController editingController,
    CodeChunkController chunkController,
    CodeIndicatorValueNotifier notifier,
  ) {
    return Container(
      width: 56,
      color: kEditorPanelBg,
      padding: const EdgeInsets.only(top: 16, right: 12),
      alignment: Alignment.topRight,
      child: DefaultCodeLineNumber(
        controller: editingController,
        notifier: notifier,
        textStyle: TextStyle(
          color: const Color(0xFFB0B7C3),
          fontSize: _editorFontSize,
          height: _editorLineHeight,
          fontFamily: kEditorFontFamily,
          fontFamilyFallback: kEditorFontFallback,
        ),
        // 当前行号高亮
        focusedTextStyle: TextStyle(
          color: kAccent,
          fontSize: _editorFontSize,
          height: _editorLineHeight,
          fontWeight: FontWeight.w700,
          fontFamily: kEditorFontFamily,
          fontFamilyFallback: kEditorFontFallback,
        ),
      ),
    );
  }

  // ── 滚动条 ─────────────────────────────────────────────────────────────

  Widget _buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    final isVertical =
        details.direction == AxisDirection.down || details.direction == AxisDirection.up;
    return _AppScrollbar(
      controller: details.controller,
      isVertical: isVertical,
      child: child,
    );
  }

  // ── 分割线 ─────────────────────────────────────────────────────────────

  Widget _buildDivider(double totalWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        onHorizontalDragStart: (_) => setState(() => _isDragging = true),
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dividerPosition += details.delta.dx / totalWidth;
            _dividerPosition = _dividerPosition.clamp(0.2, 0.8);
          });
        },
        onHorizontalDragEnd: (_) => setState(() => _isDragging = false),
        child: Container(
          width: 4,
          color: Colors.transparent,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 1px 分隔线
              Container(width: 1, color: _isDragging ? kAccent : kBorder),
              // 拖拽手柄
              Container(
                width: 10,
                height: 38,
                decoration: BoxDecoration(
                  color: _isDragging ? kAccent : kPreviewBg,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                      color: _isDragging ? kAccent : kBorder, width: 1),
                ),
                child: Icon(Icons.more_horiz_rounded,
                    size: 14,
                    color: _isDragging ? Colors.white : kTextSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 右侧预览面板 ───────────────────────────────────────────────────────

  Widget _buildPreviewPanel() {
    return Container(
      color: kPreviewBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _rawMarkdown.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.article_outlined,
                            size: 40,
                            color: kTextSecondary.withValues(alpha: 0.3)),
                        const SizedBox(height: 10),
                        const Text('在左侧输入 Markdown 开始预览',
                            style: TextStyle(
                                fontSize: 13, color: kTextSecondary)),
                      ],
                    ),
                  )
                : SelectionArea(
                    child: Markdown(
                      data: _rawMarkdown,
                      selectable: false,
                      builders: {'code': _MermaidCodeBlockBuilder()},
                      controller: _previewScrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      styleSheet: MarkdownStyleSheet(
                        h1: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            height: 2.2),
                        h2: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            height: 2.0),
                        h3: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            height: 1.8),
                        h4: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.6),
                        p: const TextStyle(
                            color: kTextPrimary, fontSize: 14, height: 1.7),
                        code: const TextStyle(
                            color: Color(0xFFC7254E),
                            fontSize: 13,
                            fontFamily: kEditorFontFamily),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: kBorder, width: 0.5),
                        ),
                        blockquote: const TextStyle(
                            color: kTextSecondary, fontSize: 14, height: 1.6),
                        blockquoteDecoration: BoxDecoration(
                          color: kAccent.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(4),
                          border: Border(
                            left: BorderSide(
                                color: kAccent.withValues(alpha: 0.5),
                                width: 3),
                          ),
                        ),
                        tableBorder:
                            TableBorder.all(color: kBorder, width: 0.5),
                        tableHead: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                        tableBody:
                            const TextStyle(color: kTextPrimary, fontSize: 13),
                        tableHeadAlign: TextAlign.center,
                        tableCellsDecoration:
                            const BoxDecoration(color: kPreviewBg),
                        tableColumnWidth: const FlexColumnWidth(),
                        listBullet: const TextStyle(
                            color: kAccent, fontSize: 14),
                        horizontalRuleDecoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: kBorder, width: 0.5),
                          ),
                        ),
                        strong: const TextStyle(
                            color: kTextPrimary,
                            fontWeight: FontWeight.w700),
                        em: const TextStyle(
                            color: kTextPrimary,
                            fontStyle: FontStyle.italic),
                        del: const TextStyle(
                            color: kTextSecondary,
                            decoration: TextDecoration.lineThrough),
                        a: const TextStyle(
                            color: kAccent,
                            decoration: TextDecoration.underline),
                        checkbox:
                            const TextStyle(color: kAccent, fontSize: 14),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ── 底部状态栏 ─────────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    final (row, col) = _cursorPos;
    final status = <Widget>[
      _StatusItem('Ln ${row + 1}, Col ${col + 1}'),
      _StatusItem('$_charCount 字'),
      _StatusItem('$_lineCount 行'),
      _StatusItem('UTF-8'),
    ];
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kEditorPanelBg,
        border: Border(top: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Row(
        children: [
          ...status,
          const Spacer(),
          const _StatusItem('Markdown'),
          _StatusItem(_isDirty ? '● 未保存' : '已保存',
              emphasized: _isDirty),
          _StatusItem(_mermaidBlocks > 0
              ? 'Mermaid: OK ($_mermaidBlocks 块)'
              : 'Mermaid: —'),
        ],
      ),
    );
  }

  // ── 设置弹窗 ───────────────────────────────────────────────────────────

  Future<void> _showSettings() async {
    var fontSize = _editorFontSize;
    var lineHeight = _editorLineHeight;
    var theme = _highlightTheme;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑器设置'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('字号',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 14, label: Text('14')),
                    ButtonSegment(value: 15, label: Text('15')),
                    ButtonSegment(value: 16, label: Text('16')),
                  ],
                  selected: {fontSize},
                  onSelectionChanged: (s) =>
                      setDialogState(() => fontSize = s.first),
                ),
                const SizedBox(height: 18),
                const Text('行高',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 1.6, label: Text('1.6')),
                    ButtonSegment(value: 1.7, label: Text('1.7')),
                    ButtonSegment(value: 1.8, label: Text('1.8')),
                  ],
                  selected: {lineHeight},
                  onSelectionChanged: (s) =>
                      setDialogState(() => lineHeight = s.first),
                ),
                const SizedBox(height: 18),
                const Text('语法高亮主题',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: kHighlightThemeNames.entries
                      .map((e) =>
                          ButtonSegment(value: e.key, label: Text(e.key)))
                      .toList(),
                  selected: {theme},
                  onSelectionChanged: (s) =>
                      setDialogState(() => theme = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _editorFontSize = fontSize;
                  _editorLineHeight = lineHeight;
                  _highlightTheme =
                      kHighlightThemeNames[theme] ?? _highlightTheme;
                });
                Navigator.of(dialogContext).pop();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Mermaid 代码块 builder ────────────────────────────────────────────────

/// 命中 ```mermaid 代码块时替换为 [MermaidView]，其余代码块放行默认渲染。
class _MermaidCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.attributes['class'] != 'language-mermaid') return null;
    final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return MermaidView(source: source);
  }
}

// ─── 标题栏按钮 ─────────────────────────────────────────────────────────────

class _TitleBarBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TitleBarBtn({required this.icon, required this.onTap});

  @override
  State<_TitleBarBtn> createState() => _TitleBarBtnState();
}

class _TitleBarBtnState extends State<_TitleBarBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.black.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon, color: Colors.black54, size: 16),
        ),
      ),
    );
  }
}

// ─── 工具栏图标按钮 ─────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool enabled;

  const _IconBtn({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: active ? onTap : null,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(icon,
                size: 17,
                color: active
                    ? kTextPrimary
                    : kTextSecondary.withValues(alpha: 0.35)),
          ),
        ),
      ),
    );
  }
}

// ─── 标题下拉菜单 ───────────────────────────────────────────────────────────

class _HeadingMenu extends StatelessWidget {
  final ValueChanged<int> onSelected;
  const _HeadingMenu({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '标题',
      offset: const Offset(0, 34),
      icon: const Icon(Icons.title_rounded, size: 17),
      color: kPreviewBg,
      onSelected: onSelected,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 1, child: Text('H1')),
        PopupMenuItem(value: 2, child: Text('H2')),
        PopupMenuItem(value: 3, child: Text('H3')),
        PopupMenuItem(value: 4, child: Text('H4')),
        PopupMenuItem(value: 5, child: Text('H5')),
        PopupMenuItem(value: 6, child: Text('H6')),
      ],
    );
  }
}

// ─── 状态栏条目 ─────────────────────────────────────────────────────────────

class _StatusItem extends StatelessWidget {
  final String text;
  final bool emphasized;
  const _StatusItem(this.text, {this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: emphasized ? kAccent : kTextSecondary,
          fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

// ─── 自定义滚动条 ───────────────────────────────────────────────────────────

/// 8px 细滚动条，滑块悬停时变深；轨道保持透明。
class _AppScrollbar extends StatefulWidget {
  final ScrollController? controller;
  final bool isVertical;
  final Widget child;

  const _AppScrollbar({
    required this.controller,
    required this.isVertical,
    required this.child,
  });

  @override
  State<_AppScrollbar> createState() => _AppScrollbarState();
}

class _AppScrollbarState extends State<_AppScrollbar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: RawScrollbar(
        controller: controller,
        thumbVisibility: true,
        thickness: 8,
        radius: const Radius.circular(4),
        thumbColor:
            _hovered ? const Color(0xFFA8B0BA) : const Color(0xFFD0D5DC),
        scrollbarOrientation: widget.isVertical
            ? ScrollbarOrientation.right
            : ScrollbarOrientation.bottom,
        child: widget.child,
      ),
    );
  }
}
