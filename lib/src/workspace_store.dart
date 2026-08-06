import 'dart:convert';
import 'dart:io';

/// Orbby 工作区文件管理器。
///
/// 管理 `~/.orbby/orbby_md_editor/` 目录：
/// - `files/`   —— 项目 md 文件工作区（左侧面板上半部分列出）
/// - `history.json` —— 打开过的 files/ 之外的文件路径引用（左侧面板下半部分）
///
/// 目录约定与 [LogService]（写 `~/.orbby/orbby.log`）同一体系，位于用户主目录。
class WorkspaceStore {
  WorkspaceStore();

  /// 编辑器支持的文件扩展名（不含点），小写。
  static const supportedExtensions = ['md', 'markdown', 'txt'];

  /// 用户主目录（Windows 取 USERPROFILE，否则 HOME）。
  static String get homeDir {
    return Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
  }

  /// `~/.orbby/orbby_md_editor/`
  String get rootDir => '$homeDir${Platform.pathSeparator}.orbby'
      '${Platform.pathSeparator}orbby_md_editor';

  /// `~/.orbby/orbby_md_editor/files/`
  String get filesDir => '$rootDir${Platform.pathSeparator}files';

  /// `~/.orbby/orbby_md_editor/history.json`
  String get historyPath => '$rootDir${Platform.pathSeparator}history.json';

  /// 确保工作区目录结构存在（递归创建）。
  Future<void> ensureReady() async {
    final dir = Directory(filesDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// 列出 files/ 根目录下支持的文档文件（不递归），按文件名排序。
  Future<List<File>> listProjectFiles() async {
    final dir = Directory(filesDir);
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!_isSupported(entity.path)) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return files;
  }

  /// 判断文件扩展名是否为编辑器支持的文档格式（大小写不敏感）。
  bool _isSupported(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0 || dot == path.length - 1) return false;
    final ext = path.substring(dot + 1).toLowerCase();
    return supportedExtensions.contains(ext);
  }

  /// 规范化路径：统一 `/` 分隔符 + 转小写，用于跨平台前缀比较。
  String _normalize(String path) {
    return path.replaceAll('\\', '/').toLowerCase();
  }

  /// 判断 [path] 是否位于工作区 files/ 目录内。
  ///
  /// 落在 files/ 内的文件视为"项目文件"，不记入历史；反之（外部文件）记入历史。
  bool isInsideFilesDir(String path) {
    final base = _normalize(filesDir);
    final target = _normalize(path);
    if (target == base) return true;
    return target.startsWith('$base/');
  }

  /// 读取历史记录（JSON 字符串数组，最新在前）。
  Future<List<String>> loadHistory() async {
    final file = File(historyPath);
    if (!await file.exists()) return const [];
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final paths = decoded.whereType<String>().toList();
      return _dedupe(paths);
    } catch (_) {
      // 文件损坏时当作空历史，不阻塞启动
      return const [];
    }
  }

  /// 记录一个打开过的外部文件路径到历史（去重后插到最前，写回磁盘）。
  Future<void> addHistory(String path) async {
    final current = await loadHistory();
    final updated = [path, ...current.where((p) => p != path)];
    await _writeHistory(updated);
  }

  /// 从历史中移除指定路径。
  Future<void> removeHistory(String path) async {
    final current = await loadHistory();
    final updated = current.where((p) => p != path).toList();
    await _writeHistory(updated);
  }

  /// 清空历史。
  Future<void> clearHistory() async {
    await _writeHistory(const []);
  }

  Future<void> _writeHistory(List<String> paths) async {
    final file = File(historyPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(paths));
  }

  /// 去重并保持顺序。
  List<String> _dedupe(List<String> paths) {
    final seen = <String>{};
    final result = <String>[];
    for (final p in paths) {
      if (seen.add(p)) result.add(p);
    }
    return result;
  }
}
