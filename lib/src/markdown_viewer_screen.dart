import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_editor/re_editor.dart';
import 'package:screen_retriever/screen_retriever.dart';

import 'editor_theme.dart';
import 'log_service.dart';
import 'mermaid_view.dart';
import 'pdf_export.dart';
import 'package:window_manager/window_manager.dart';
import 'ui_kit.dart';
import 'workspace_store.dart';

// ─── 主内容组件 ─────────────────────────────────────────────────────────────

class MarkdownViewerScreen extends StatefulWidget {
  const MarkdownViewerScreen({super.key, this.initialFilePath});

  final String? initialFilePath;

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
  bool _showWorkspace = false;
  bool _showMenu = false;
  // 默认只显示预览区，可通过文件名左侧按钮打开编辑区。
  bool _showEditor = false;
  bool _isMaximized = false;
  Rect _restoreBounds = const Rect.fromLTWH(0, 0, 1400, 1000);
  String? _currentFilePath;

  // 左侧工作区
  final _store = WorkspaceStore();
  List<String> _projectFiles = []; // files/ 目录下的文件名
  List<String> _historyPaths = []; // 历史文件路径
  double _workspaceWidth = 240;
  bool _isWorkspaceDragging = false;

  // 编辑器设置（可在设置弹窗中调整）
  double _editorFontSize = 14;
  double _editorLineHeight = 1.8;
  String _highlightTheme = 'github';

  // 保存状态：记录最后一次保存时的文本，用于 dirty 判断
  String _savedBaseline = '';

  // 导出 PDF 进行中：控制导出按钮显示转圈并禁用
  bool _isExporting = false;
  // 导出图表 PNG 进行中：控制导出按钮显示转圈并禁用
  bool _isExportingPng = false;

  @override
  void initState() {
    super.initState();
    _savedBaseline = _controller.text;
    _controller.addListener(_onEditorChanged);
    // 直接监听全局键盘，确保 Ctrl+S 在编辑器聚焦时也能触发保存
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _loadWorkspace();
    final initialFilePath = widget.initialFilePath;
    if (initialFilePath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInitialFile(initialFilePath);
      });
    }
  }

  Future<void> _loadInitialFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) _showSnackBar('文件不存在: $path', error: true);
      return;
    }
    final ok = await _loadFile(path);
    if (ok && mounted) {
      _showSnackBar('已打开 ${file.uri.pathSegments.last}');
      if (!_store.isInsideFilesDir(path)) {
        await _store.addHistory(path);
        await _refreshWorkspace();
      }
    }
  }

  /// 启动时加载左侧工作区：确保目录存在，列出项目文件与历史记录。
  Future<void> _loadWorkspace() async {
    try {
      await _store.ensureReady();
      final projectFiles = await _store.listProjectFiles();
      final historyPaths = await _store.loadHistory();
      if (!mounted) return;
      setState(() {
        _projectFiles = projectFiles.map((f) => f.path).toList();
        _historyPaths = historyPaths;
      });
    } catch (e) {
      LogService.error('加载工作区失败', exception: e);
    }
  }

  /// 刷新左侧工作区（项目文件 + 历史）。
  Future<void> _refreshWorkspace() async {
    final projectFiles = await _store.listProjectFiles();
    final historyPaths = await _store.loadHistory();
    if (!mounted) return;
    setState(() {
      _projectFiles = projectFiles.map((f) => f.path).toList();
      _historyPaths = historyPaths;
    });
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

  Future<void> _openMarkdownLink(String text, String? href, String title) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 将块级 LaTeX 公式转换为内部 math 代码块，交给公式组件渲染。
  String get _markdownWithMathBlocks => _rawMarkdown.replaceAllMapped(
        RegExp(r'\$\$\s*([\s\S]*?)\s*\$\$', multiLine: true),
        (match) => '\n\n```math\n${match.group(1)!.trim()}\n```\n\n',
      );
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

  /// 创建文件：弹窗输入文件名，在项目 files/ 目录创建并打开编辑。
  Future<void> _newFile() async {
    if (!await _confirmDiscardIfDirty()) return;
    if (!mounted) return;

    final input = await _promptFileName();
    if (input == null || !mounted) return;

    // 规范化文件名
    var name = input.trim();
    if (name.isEmpty) {
      _showSnackBar('文件名不能为空', error: true);
      return;
    }
    // Windows 路径非法字符校验
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(name)) {
      _showSnackBar('文件名包含非法字符', error: true);
      return;
    }
    // 未带支持扩展名时自动补 .md
    final dot = name.lastIndexOf('.');
    final hasSupportedExt = dot > 0 &&
        WorkspaceStore.supportedExtensions
            .contains(name.substring(dot + 1).toLowerCase());
    if (!hasSupportedExt) name = '$name.md';

    final path = '${_store.filesDir}${Platform.pathSeparator}$name';
    final file = File(path);
    if (await file.exists()) {
      _showSnackBar('文件已存在: $name', error: true);
      return;
    }

    try {
      await file.writeAsString('');
      final ok = await _loadFile(path);
      await _refreshWorkspace();
      if (ok && mounted) {
        _showSnackBar('已创建: $name');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('创建文件失败: $e', error: true);
      }
    }
  }

  /// 弹窗输入新建文件名；返回 null 表示取消。
  ///
  /// 输入框封装为 [_FileNameField]（内部持有并释放 TextEditingController），
  /// 避免对话框退场动画期间 controller 被提前 dispose 导致崩溃。
  Future<String?> _promptFileName() async {
    var value = '';
    return showModernDialog<String>(
      context,
      ModernDialogFrame(
        icon: Icons.note_add_rounded,
        title: '创建文件',
        subtitle: '将保存到项目 files/ 目录',
        width: 360,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          GradientButton(
            label: '创建',
            icon: Icons.check_rounded,
            onPressed: () => Navigator.of(context).pop(value),
          ),
        ],
        children: [
          _FileNameField(
            onChanged: (v) => value = v,
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
    );
  }

  /// 载入指定路径的文件到编辑器；成功返回 true。
  /// 历史区 / 项目区点击共用此入口。
  Future<bool> _loadFile(String path) async {
    try {
      final content = await File(path).readAsString();
      _controller.text = content;
      _currentFilePath = path;
      _savedBaseline = content;
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      if (mounted) {
        _showSnackBar('读取文件失败: $e', error: true);
      }
      return false;
    }
  }

  /// 有未保存修改时弹出确认；用户选择"放弃修改"返回 true。
  Future<bool> _confirmDiscardIfDirty() async {
    if (!_isDirty) return true;
    if (!mounted) return false;
    final result = await showModernDialog<bool>(
      context,
      ModernDialogFrame(
        icon: Icons.warning_amber_rounded,
        title: '未保存的修改',
        subtitle: '切换将丢失未保存内容',
        width: 380,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          GradientButton(
            label: '放弃修改',
            icon: Icons.delete_sweep_rounded,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
        children: const [
          Text('当前文件有未保存的修改，继续操作将丢失这些修改。',
              style: TextStyle(fontSize: 13.5, height: 1.6, color: kTextPrimary)),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _openFile() async {
    if (!await _confirmDiscardIfDirty()) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.first.path;
    if (filePath == null) return;

    final ok = await _loadFile(filePath);
    if (ok && mounted) {
      _showSnackBar('已加载: ${result.files.first.name}');
      // files/ 之外打开的文件记录到历史
      if (!_store.isInsideFilesDir(filePath)) {
        await _store.addHistory(filePath);
        await _refreshWorkspace();
      }
    }
  }

  Future<void> _saveFile() async {
    String? savePath = _currentFilePath;
    // 未命名（新建）文件：默认保存到工作区 files/ 目录
    savePath ??= await FilePicker.platform.saveFile(
      dialogTitle: '保存 Markdown 文件',
      fileName: '新建文档.md',
      initialDirectory: _store.filesDir,
      type: FileType.custom,
      allowedExtensions: ['md', 'markdown', 'txt'],
    );
    if (savePath == null) return;

    try {
      await File(savePath).writeAsString(_controller.text);
      setState(() {
        _currentFilePath = savePath;
        _savedBaseline = _controller.text;
      });
      if (mounted) {
        final name = savePath.split(Platform.pathSeparator).last;
        _showSnackBar('已保存: $name');
      }
      // 保存到 files/ 内的文件，刷新项目文件列表
      if (_store.isInsideFilesDir(savePath)) {
        await _refreshWorkspace();
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('保存失败: $e', error: true);
      }
    }
  }

  /// 重新从磁盘读取当前文件，丢弃内存中的编辑内容。
  Future<void> _reloadFile() async {
    final path = _currentFilePath;
    if (path == null) {
      _showSnackBar('当前没有打开的文件', error: true);
      return;
    }
    if (!await _confirmDiscardIfDirty()) return;
    if (!await File(path).exists()) {
      _showSnackBar('文件已不存在', error: true);
      return;
    }
    final ok = await _loadFile(path);
    if (ok && mounted) {
      _showSnackBar('已重新加载');
    }
  }

  /// 将预览内容导出为 PDF（Edge 无头渲染，含 Mermaid 图表）。
  ///
  /// 导出期间显示加载状态：导出按钮转圈并禁用。
  Future<void> _exportPdf() async {
    if (_rawMarkdown.trim().isEmpty) {
      _showSnackBar('没有可导出的内容', error: true);
      return;
    }
    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: '导出为PDF',
      fileName: '文档.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (outputPath == null) return;

    // 默认补 .pdf 后缀：用户输入的文件名未带扩展名时自动加上
    var path = outputPath;
    if (!path.toLowerCase().endsWith('.pdf')) {
      path = '$path.pdf';
    }

    if (mounted) setState(() => _isExporting = true);
    try {
      final (ok, message) = await exportToPdf(_rawMarkdown, path);
      if (!mounted) return;
      if (ok) {
        _showSnackBar(message);
      } else {
        _showExportError(message);
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// 将所有 Mermaid 图表导出为 PNG：选择目录后自动创建「文件名+图表」文件夹，
  /// 导出期间按钮显示转圈并禁用。
  Future<void> _exportChartsPng() async {
    if (_mermaidBlocks == 0) {
      _showSnackBar('没有 Mermaid 图表', error: true);
      return;
    }
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择图表导出目录',
    );
    if (dir == null || !mounted) return;

    final target = '$dir${Platform.pathSeparator}$_fileNameStem图表';
    if (mounted) setState(() => _isExportingPng = true);
    try {
      final (ok, message) = await exportChartsToPng(_rawMarkdown, target);
      if (!mounted) return;
      if (ok) {
        _showSnackBar(message);
      } else {
        _showExportError(message);
      }
    } finally {
      if (mounted) setState(() => _isExportingPng = false);
    }
  }

  /// 当前文件名去掉扩展名；未命名文件返回「未命名」。
  Future<void> _showExportDialog() async {
    if (_isExporting || _isExportingPng) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        elevation: 8,
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x26000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('导出',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: kTextPrimary)),
              const SizedBox(height: 4),
              const Text('选择导出模式',
                  style: TextStyle(fontSize: 12, color: kTextSecondary)),
              const SizedBox(height: 14),
              _ExportModeTile(
                icon: Icons.picture_as_pdf_rounded,
                title: '导出 PDF',
                subtitle: '将预览内容导出为 PDF 文件',
                onTap: () => Navigator.of(dialogContext).pop('pdf'),
              ),
              const SizedBox(height: 8),
              _ExportModeTile(
                icon: Icons.image_rounded,
                title: '导出图片',
                subtitle: '导出文档中的 Mermaid 图表',
                onTap: () => Navigator.of(dialogContext).pop('image'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (mode == 'pdf') {
      await _exportPdf();
    } else if (mode == 'image') {
      await _exportChartsPng();
    }
  }

  String get _fileNameStem {
    if (_currentFilePath == null) return '未命名';
    final base = _currentFilePath!.split(Platform.pathSeparator).last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  /// 导出失败时用弹窗展示完整错误（可选中复制），避免 SnackBar 一闪而过。
  void _showExportError(String message) {
    if (!mounted) return;
    showModernDialog<void>(
      context,
      ModernDialogFrame(
        icon: Icons.error_outline_rounded,
        title: '导出失败',
        subtitle: '以下是详细信息，可选中复制',
        width: 440,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: SelectableText(
                message,
                style: const TextStyle(
                    fontSize: 13, height: 1.6, color: kTextPrimary),
              ),
            ),
          ),
        ],
      ),
    );
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
      // 无边框窗口不能调用系统最大化，因此根据窗口当前中心点选择屏幕。
      // 这里不能固定使用 primary display，否则从副屏点击最大化时会跳回主屏。
      final bounds = _restoreBounds;
      final center = Offset(
        bounds.left + bounds.width / 2,
        bounds.top + bounds.height / 2,
      );
      final displays = await screenRetriever.getAllDisplays();
      final display = displays.firstWhere(
        (item) {
          final position = item.visiblePosition ?? Offset.zero;
          final size = item.visibleSize ?? item.size;
          return center.dx >= position.dx &&
              center.dx < position.dx + size.width &&
              center.dy >= position.dy &&
              center.dy < position.dy + size.height;
        },
        orElse: () => displays.isNotEmpty
            ? displays.first
            : throw StateError('No display found'),
      );
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
            Expanded(
              child: Row(
                  children: [
                  // 左侧工作区：项目文件 + 历史
                  if (_showWorkspace) ...[
                    _buildWorkspace(),
                    _buildWorkspaceDivider(),
                  ],
                  Expanded(
                    child: Column(
                      children: [
                        if (_showEditor) _buildFormatBar(),
                        Expanded(child: _buildSplitView()),
                      ],
                    ),
                  ),
                  ],
                ),
              ),
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
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFFFFFF), Color(0xFFF2F5FF)],
          ),
          border: Border(bottom: BorderSide(color: kBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 6),
            _TitleBarBtn(
                icon: Icons.menu_rounded,
                buttonSize: 36,
                iconSize: 21,
                hoverColor: kTextSecondary,
                onTap: () => setState(() {
                  _showMenu = !_showMenu;
                  _showWorkspace = _showMenu;
                })),
            if (_showMenu) ...[
              const SizedBox(width: 6),
              _IconBtn(icon: Icons.folder_open_rounded, tooltip: '打开文件', onTap: _openFile, color: kTextSecondary),
              _IconBtn(icon: Icons.settings_rounded, tooltip: '设置', onTap: _showSettings, color: kTextSecondary),
              _IconBtn(icon: Icons.refresh_rounded, tooltip: '刷新', onTap: _reloadFile, color: kTextSecondary),
              _IconBtn(
                  icon: Icons.file_download_outlined,
                  tooltip: '导出',
                  onTap: _showExportDialog,
                  loading: _isExporting || _isExportingPng,
                  color: kTextSecondary),
              _toolbarSeparator(),
            ],
            const SizedBox(width: 4),
            _buildFileName(),
            const Spacer(),
            _IconBtn(
                icon: _showEditor ? Icons.edit_off_rounded : Icons.edit_rounded,
                tooltip: _showEditor ? '隐藏编辑区' : '显示编辑区',
                color: kTextSecondary.withValues(alpha: 0.7),
                hoverColor: kTextSecondary,
                onTap: () => setState(() => _showEditor = !_showEditor)),
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: kBorder.withValues(alpha: 0.45),
            ),
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
                icon: Icons.close_rounded,
                onTap: () => windowManager.close(),
                danger: true),
          ],
        ),
      ),
    );
  }

  // ── 左侧工作区 ───────────────────────────────────────────────────────────

  /// 左侧面板：上半项目文件区，下半历史区。
  Widget _buildWorkspace() {
    return Container(
      width: _workspaceWidth,
      color: kEditorPanelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: _buildFileListPanel(
              title: 'Project',
              onAction: _refreshWorkspace,
              actionIcon: Icons.refresh_rounded,
              leadingAction: _newFile,
              leadingActionIcon: Icons.add_rounded,
              leadingActionTooltip: '创建文件',
              actionTooltip: '刷新',
              emptyText: '暂无文件',
              children: _projectFiles
                  .map((p) => _buildProjectFileItem(p))
                  .toList(),
            ),
          ),
          // 上下分区线
          Container(height: 1, color: kBorder),
          Expanded(
            flex: 2,
            child: _buildFileListPanel(
              title: 'Recent Files',
              onAction: _clearHistory,
              actionIcon: Icons.delete_sweep_rounded,
              actionTooltip: '清空历史',
              emptyText: '暂无历史',
              children:
                  _historyPaths.map((p) => _buildHistoryItem(p)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 项目文件列表项：点击在编辑区打开。
  Widget _buildProjectFileItem(String path) {
    final name = path.split(Platform.pathSeparator).last;
    return _WorkspaceListItem(
      label: name,
      sublabel: path,
      active: _currentFilePath == path,
      onTap: () => _onProjectFileTap(path),
    );
  }

  Future<void> _onProjectFileTap(String path) async {
    if (!await _confirmDiscardIfDirty()) return;
    final ok = await _loadFile(path);
    if (ok && mounted) {
      _showSnackBar('已加载: ${path.split(Platform.pathSeparator).last}');
    }
  }

  /// 历史列表项：点击重新打开；文件不存在时提示移除。
  Widget _buildHistoryItem(String path) {
    final name = path.split(Platform.pathSeparator).last;
    return _WorkspaceListItem(
      label: name,
      sublabel: path,
      active: _currentFilePath == path,
      onTap: () => _onHistoryTap(path),
    );
  }

  Future<void> _onHistoryTap(String path) async {
    if (!await _confirmDiscardIfDirty()) return;
    if (!await File(path).exists()) {
      final name = path.split(Platform.pathSeparator).last;
      final remove = await _confirmRemoveHistory(name, path);
      if (remove == true) {
        await _store.removeHistory(path);
        await _refreshWorkspace();
      }
      return;
    }
    final ok = await _loadFile(path);
    if (ok && mounted) {
      _showSnackBar('已加载: ${path.split(Platform.pathSeparator).last}');
    }
  }

  Future<bool> _confirmRemoveHistory(String name, String path) async {
    if (!mounted) return false;
    final result = await showModernDialog<bool>(
      context,
      ModernDialogFrame(
        icon: Icons.link_off_rounded,
        title: '文件不存在',
        subtitle: '历史记录指向的文件已失效',
        width: 380,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留'),
          ),
          GradientButton(
            label: '移除',
            icon: Icons.delete_forever_rounded,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
        children: [
          Text('「$name」已不存在或已被移动，是否从历史中移除？',
              style: const TextStyle(
                  fontSize: 13.5, height: 1.6, color: kTextPrimary)),
          const SizedBox(height: 8),
          Text(path,
              style: const TextStyle(fontSize: 12, color: kTextSecondary)),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _clearHistory() async {
    await _store.clearHistory();
    await _refreshWorkspace();
  }

  /// 通用文件列表面板：标题行（含操作按钮）+ 可选的列表上方全宽区域 + 列表。
  Widget _buildFileListPanel({
    required String title,
    IconData? icon,
    required VoidCallback? onAction,
    required IconData actionIcon,
    required String actionTooltip,
    VoidCallback? leadingAction,
    IconData? leadingActionIcon,
    String? leadingActionTooltip,
    required String emptyText,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 面板标题行
        Container(
          height: 38,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: const BoxDecoration(
            color: kEditorPanelBg,
            border: Border(bottom: BorderSide(color: kBorder, width: 0.5)),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: kTextSecondary),
                const SizedBox(width: 8),
              ],
              Text(title,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: kTextPrimary)),
              const Spacer(),
              if (leadingAction != null && leadingActionIcon != null)
                _MiniBtn(
                    icon: leadingActionIcon,
                    tooltip: leadingActionTooltip ?? '',
                    onTap: leadingAction,
                    large: true),
              if (onAction != null)
                _MiniBtn(
                    icon: actionIcon,
                    tooltip: actionTooltip,
                    onTap: onAction,
                    large: leadingAction != null),
            ],
          ),
        ),
        // 列表上方全宽区域（如创建文件按钮）
        // 文件列表
        Expanded(
          child: children.isEmpty
              ? Center(
                  child: Text(emptyText,
                      style:
                          const TextStyle(fontSize: 12, color: kTextSecondary)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: children.length,
                  itemBuilder: (_, i) => children[i],
                ),
        ),
      ],
    );
  }

  /// 项目区"创建文件"全宽渐变按钮：点击新建文件，保存到 files/ 目录。
  Widget _buildCreateFileButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: GradientButton(
        label: '创建文件',
        icon: Icons.add_rounded,
        onPressed: _newFile,
        expanded: true,
        muted: true,
      ),
    );
  }

  /// 工作区可拖拽分隔线，调节左侧面板宽度。
  Widget _buildWorkspaceDivider() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        onHorizontalDragStart: (_) =>
            setState(() => _isWorkspaceDragging = true),
        onHorizontalDragUpdate: (details) {
          setState(() {
            _workspaceWidth =
                (_workspaceWidth + details.delta.dx).clamp(180, 320);
          });
        },
        onHorizontalDragEnd: (_) =>
            setState(() => _isWorkspaceDragging = false),
        child: Container(
          width: 5,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: _isWorkspaceDragging ? kAccent : kBorder,
            ),
          ),
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
          const SizedBox(width: 6),
          _IconBtn(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onTap: _reloadFile),
          _toolbarSeparator(),
          _buildFileName(),
        ],
      ),
    );
  }

  /// 第二行：文本格式栏 —— Markdown 快捷操作 + 撤销/重做
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
    final name = '$stem.md';
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
                color: kTextPrimary, fontSize: 13, fontWeight: FontWeight.w400)),
      ],
    );
  }

  // ── 分割视图 ───────────────────────────────────────────────────────────

  Widget _buildSplitView() {
    if (!_showEditor) return _buildPreviewPanel();

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
                        SvgPicture.asset(
                          'assets/无内容.svg',
                          width: 180,
                          height: 128,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  )
                : Markdown(
                      data: _markdownWithMathBlocks,
                      onTapLink: _openMarkdownLink,
                      selectable: true,
                      builders: {
                        'code': _MermaidCodeBlockBuilder(),
                      },
                      controller: _previewScrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 48, vertical: 16),
                      styleSheet: MarkdownStyleSheet(
                        h1: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            height: 2.6),
                        h2: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            height: 2.4),
                        h3: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            height: 2.2),
                        h4: const TextStyle(
                            color: kTextPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            height: 2.0),
                        p: const TextStyle(
                            color: kTextPrimary, fontSize: 16, height: 1.7),
                        code: const TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontFamily: kEditorFontFamily),
                        codeblockPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 20),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquote: const TextStyle(
                            color: kTextSecondary, fontSize: 16, height: 1.6),
                        blockquotePadding: const EdgeInsets.fromLTRB(
                            14, 4, 8, 4),
                        blockquoteDecoration: BoxDecoration(
                          color: Colors.transparent,
                          border: Border(
                            left: BorderSide(
                                color: Color(0xFFB0B7C3),
                                width: 1.5),
                          ),
                        ),
                        tableBorder: TableBorder(
                        ),
                        tableHead: const TextStyle(
                            color: Color(0xFF4B5563),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            height: 1.5),
                        tableBody:
                            const TextStyle(
                                color: kTextPrimary, fontSize: 15, height: 1.5),
                        tableHeadAlign: TextAlign.left,
                        tablePadding:
                            const EdgeInsets.symmetric(vertical: 30),
                        tableCellsDecoration:
                            const BoxDecoration(color: Color(0xFFFAFBFC)),
                        tableColumnWidth: const FlexColumnWidth(),
                        listBullet: const TextStyle(
                            color: kTextPrimary, fontSize: 16),
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
                            decoration: TextDecoration.none),
                        checkbox:
                            const TextStyle(color: Colors.black, fontSize: 16),
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
          // 品牌渐变竖条装饰
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              gradient: kBrandGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
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
    await showModernDialog<void>(
      context,
      StatefulBuilder(
        builder: (context, setDialogState) => ModernDialogFrame(
          icon: Icons.tune_rounded,
          title: '编辑器设置',
          subtitle: '调整编辑体验',
          width: 400,
          actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          GradientButton(
            label: '应用',
            icon: Icons.check_rounded,
            onPressed: () {
              setState(() {
                _editorFontSize = fontSize;
                _editorLineHeight = lineHeight;
                _highlightTheme =
                    kHighlightThemeNames[theme] ?? _highlightTheme;
              });
              Navigator.of(context).pop();
            },
          ),
        ],
        children: [
          _settingLabel(Icons.format_size_rounded, _cFontSize, '字号'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<double>(
              segments: const [
                ButtonSegment(value: 14, label: Text('14')),
                ButtonSegment(value: 15, label: Text('15')),
                ButtonSegment(value: 16, label: Text('16')),
              ],
              selected: {fontSize},
              onSelectionChanged: (s) =>
                  setDialogState(() => fontSize = s.first),
              style: _segmentedStyle(_cFontSize),
            ),
          ),
          const SizedBox(height: 20),
          _settingLabel(Icons.format_line_spacing_rounded, _cLineHeight, '行高'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<double>(
              segments: const [
                ButtonSegment(value: 1.6, label: Text('1.6')),
                ButtonSegment(value: 1.7, label: Text('1.7')),
                ButtonSegment(value: 1.8, label: Text('1.8')),
              ],
              selected: {lineHeight},
              onSelectionChanged: (s) =>
                  setDialogState(() => lineHeight = s.first),
              style: _segmentedStyle(_cLineHeight),
            ),
          ),
          const SizedBox(height: 20),
          _settingLabel(Icons.palette_rounded, _cTheme, '语法高亮主题'),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: kHighlightThemeNames.entries
                  .map((e) => ButtonSegment(value: e.key, label: Text(e.key)))
                  .toList(),
              selected: {theme},
              onSelectionChanged: (s) => setDialogState(() => theme = s.first),
              style: _segmentedStyle(_cTheme),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ── 设置弹窗辅助 ────────────────────────────────────────────────────────

  static const _cFontSize = Color(0xFF448AFF); // 蓝
  static const _cLineHeight = Color(0xFF00BFA5); // 青
  static const _cTheme = Color(0xFF7C4DFF); // 紫

  /// 设置项标题：彩色圆底图标 + 文字。
  Widget _settingLabel(IconData icon, Color color, String text) {
    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: 8),
        Text(text,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: kTextPrimary)),
      ],
    );
  }

  /// 分段按钮样式：选中时填充主题色。
  ButtonStyle _segmentedStyle(Color color) {
    return ButtonStyle(
      visualDensity: VisualDensity.compact,
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? color : Colors.transparent),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Colors.white : kTextSecondary),
      side: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? BorderSide(color: color)
              : const BorderSide(color: kBorder)),
      shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
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
    md.Element? codeElement;
    if (element.tag == 'pre' && element.children != null) {
      for (final child in element.children!) {
        if (child is md.Element && child.tag == 'code') {
          codeElement = child;
          break;
        }
      }
    } else if (element.tag == 'code') {
      codeElement = element;
    }
    final language = codeElement?.attributes['class'];
    if (language == 'language-mermaid') {
      final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
      return SizedBox(
        width: double.infinity,
        child: MermaidView(source: source),
      );
    }
    if (language == null) return null;
    final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    if (language == 'language-math' && element.tag == 'code') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: SizedBox(
          width: double.infinity,
          child: Center(
            child: Math.tex(
              source.trim(),
          mathStyle: MathStyle.display,
          textStyle: const TextStyle(fontSize: 18, color: Colors.black),
          onErrorFallback: (error) => Text(
            source.trim(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, color: Colors.black),
          ),
        ),
          ),
        ),
      );
    }
    if (element.tag != 'pre') return null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: kBorder, width: 0.5),
            bottom: BorderSide(color: kBorder, width: 0.5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              language.replaceFirst('language-', '').toUpperCase(),
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              source,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 13,
                fontFamily: kEditorFontFamily,
                height: 1.8,
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final language = element.attributes['class'];
    if (language == null || language == 'language-mermaid') return null;
    final source = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          color: Colors.black,
          fontSize: 13,
          fontFamily: kEditorFontFamily,
          height: 1.55,
        ),
        children: [TextSpan(text: source)],
      ),
    );
  }

}

// ─── 标题栏按钮 ─────────────────────────────────────────────────────────────

class _TitleBarBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? hoverColor;
  final double buttonSize;
  final double iconSize;
  final bool danger; // 关闭按钮 hover 红色
  const _TitleBarBtn({
    required this.icon,
    required this.onTap,
    this.hoverColor,
    this.danger = false,
    this.buttonSize = 28,
    this.iconSize = 16,
  });

  @override
  State<_TitleBarBtn> createState() => _TitleBarBtnState();
}

class _TitleBarBtnState extends State<_TitleBarBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.danger
        ? Colors.red
        : (widget.hoverColor ?? kAccent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.buttonSize,
          height: widget.buttonSize,
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon,
              size: widget.iconSize,
              color: _hovered
                  ? Colors.white
                  : (widget.danger ? Colors.black54 : kTextSecondary)),
        ),
      ),
    );
  }
}

class _ExportModeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ExportModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF4F6F8),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 21, color: kTextSecondary),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: kTextPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 11.5, color: kTextSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: kTextSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 工具栏图标按钮 ─────────────────────────────────────────────────────────

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final Widget? iconWidget;
  final String tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final bool loading; // 显示转圈并禁用点击
  final Color? color; // 常态图标色；null 用 kTextPrimary
  final Color? hoverColor; // hover 图标色；null 用 kAccent

  const _IconBtn({
    required this.icon,
    this.iconWidget,
    required this.tooltip,
    this.onTap,
    this.enabled = true,
    this.loading = false,
    this.color,
    this.hoverColor,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null && !widget.loading;
    final hoverColor = widget.hoverColor ?? kAccent;
    final color = !active
        ? kTextSecondary.withValues(alpha: 0.35)
        : _hovered
            ? hoverColor
            : (widget.color ?? kTextPrimary);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: active ? widget.onTap : null,
            splashColor: hoverColor.withValues(alpha: 0.15),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: active && _hovered
                    ? hoverColor.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: widget.loading
                  ? SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: widget.color ?? kAccent,
                      ),
                    )
              : widget.iconWidget ?? Icon(widget.icon, size: 17, color: color),
            ),
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

// ─── 新建文件输入框 ─────────────────────────────────────────────────────────

/// 新建文件名输入框：内部持有并释放 TextEditingController，
/// 生命周期与对话框 widget 绑定，避免退场动画期间 controller 已被 dispose。
class _FileNameField extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  const _FileNameField({required this.onChanged, required this.onSubmitted});

  @override
  State<_FileNameField> createState() => _FileNameFieldState();
}

class _FileNameFieldState extends State<_FileNameField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: true,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: const InputDecoration(
        hintText: '例如：笔记.md',
        isDense: true,
        border: OutlineInputBorder(),
      ),
    );
  }
}

// ─── 工作区列表项 ───────────────────────────────────────────────────────────

/// 工作区文件列表项：hover 高亮，当前打开文件高亮 + 左侧强调条。
class _WorkspaceListItem extends StatefulWidget {
  final String label;
  final String? sublabel;
  final bool active;
  final VoidCallback onTap;
  const _WorkspaceListItem({
    required this.label,
    this.sublabel,
    required this.active,
    required this.onTap,
  });

  @override
  State<_WorkspaceListItem> createState() => _WorkspaceListItemState();
}

class _WorkspaceListItemState extends State<_WorkspaceListItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? Colors.black.withValues(alpha: 0.08)
        : (_hovered ? Colors.black.withValues(alpha: 0.04) : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: BorderSide(
                  color: widget.active ? kTextSecondary : Colors.transparent, width: 3),
            ),
          ),
          child: Row(
            children: [
              widget.active
                  ? const Icon(Icons.description_rounded,
                      size: 16, color: kTextSecondary)
                  : Icon(Icons.insert_drive_file_outlined,
                      size: 14, color: kTextSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: widget.sublabel ?? widget.label,
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: kTextPrimary,
                      fontWeight:
                          widget.active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 面板迷你按钮 ───────────────────────────────────────────────────────────

/// 面板标题行上的小型图标按钮（刷新 / 清空）。
class _MiniBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool large;
  const _MiniBtn(
      {required this.icon,
      required this.tooltip,
      required this.onTap,
      this.large = false});

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: widget.large ? 30 : 24,
            height: widget.large ? 30 : 24,
            decoration: BoxDecoration(
              color: _hovered
                  ? kAccent.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(widget.icon,
                size: widget.large ? 18 : 14,
                color: _hovered ? kAccent : kTextSecondary),
          ),
        ),
      ),
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
