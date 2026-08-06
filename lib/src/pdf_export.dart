import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;

/// 把 Markdown（含 Mermaid 代码块）导出为 PDF。
///
/// 思路：预览区的 Mermaid 图表由原生 WebView2 渲染，Flutter 截图捕获不到，
/// 因此改为把 markdown 拼成**自包含 HTML**（内嵌 mermaid.min.js），调用
/// Windows 自带的 Edge 无头模式 `--print-to-pdf` 转 PDF —— 图表、多页、
/// 中文字体都能完整保留。
///
/// 返回 `(是否成功, 提示消息)`。
Future<(bool, String)> exportToPdf(String markdown, String outputPath) async {
  // 空内容检查
  if (markdown.trim().isEmpty) {
    return (false, '没有可导出的内容');
  }

  File? tempHtml;
  try {
    // 1. 提取 mermaid 块，用占位符替换（源码原样保留，避免转义问题）
    final mermaidBlocks = <String>[];
    final replaced = _extractMermaidBlocks(markdown, mermaidBlocks);

    // 2. markdown → HTML（GFM 启用表格等扩展）
    var html = md.markdownToHtml(
      replaced,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );

    // 3. 把占位符还原为 mermaid 渲染块
    for (var i = 0; i < mermaidBlocks.length; i++) {
      final escaped = const HtmlEscape().convert(mermaidBlocks[i]);
      html = html.replaceFirst(
        '<!--ORBBY_MERMAID_$i-->',
        '<div class="mermaid">$escaped</div>',
      );
    }

    // 4. 有 mermaid 块时内嵌 mermaid.min.js
    var mermaidJs = '';
    if (mermaidBlocks.isNotEmpty) {
      mermaidJs = await rootBundle.loadString('assets/mermaid/mermaid.min.js');
    }

    // 5. 组装自包含 HTML 并写临时文件
    final fullHtml = _buildHtml(html, mermaidJs);
    tempHtml = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'orbby_export_${DateTime.now().millisecondsSinceEpoch}.html');
    await tempHtml.writeAsString(fullHtml, flush: true);

    // 6. 定位系统 Edge
    final edgePath = _findEdge();
    if (edgePath == null) {
      return (false, '未找到 Microsoft Edge，无法导出 PDF');
    }

    // 7. 无头模式转 PDF（自管理超时，超时则杀掉 Edge）
    final process = await Process.start(edgePath, [
      '--headless',
      '--disable-gpu',
      // 给异步 JS（mermaid 渲染）充足时间，避免打印时图表还没画出来
      '--virtual-time-budget=10000',
      '--no-pdf-header-footer',
      '--print-to-pdf=$outputPath',
      tempHtml.path,
    ]);
    // 排空输出管道，避免缓冲阻塞
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      process.kill();
      return (false, '导出超时，已终止');
    }
    final stderr = (await stderrFuture).trim();
    final stdout = (await stdoutFuture).trim();

    // 8. 校验输出
    final out = File(outputPath);
    if (await out.exists() && await out.length() > 0) {
      return (true, '已导出 PDF');
    }
    final detail = stderr.isNotEmpty ? stderr : stdout;
    return (false, 'PDF 生成失败（Edge 退出码 $exitCode${detail.isNotEmpty ? ': $detail' : ''}）');
  } catch (e) {
    return (false, '导出失败: $e');
  } finally {
    // 清理临时 HTML
    try {
      if (tempHtml != null && await tempHtml.exists()) {
        await tempHtml.delete();
      }
    } catch (_) {}
  }
}

/// 把 Markdown 里的所有 Mermaid 图表导出为独立 PNG 图片，写入 [outputDir]。
///
/// 经 [_renderCharts] 拿到标准 SVG，再对每张图写白底 HTML、
/// 用 Edge 无头 `--screenshot` 按 viewBox 尺寸截图，得到与浏览器显示一致的 PNG。
Future<(bool, String)> exportChartsToPng(
    String markdown, String outputDir) async {
  final (ok, message, items) = await _renderCharts(markdown);
  if (!ok) return (false, message);

  await Directory(outputDir).create(recursive: true);
  var okCount = 0;
  final errors = <String>[];
  for (final item in items.cast<Map<dynamic, dynamic>>()) {
    final i = item['i'] as int;
    final svg = item['svg'];
    final err = item['error'];
    if (svg == null) {
      if (err != null) errors.add('图表${i + 1}: $err');
      continue;
    }
    final vb = _svgViewBox(svg as String);
    if (vb == null) {
      errors.add('图表${i + 1}: 无法解析图表尺寸');
      continue;
    }
    // 写临时 HTML，截图后删除
    final htmlPath = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'orbby_png_${DateTime.now().millisecondsSinceEpoch}_$i.html';
    final htmlFile = File(htmlPath);
    bool shot = false;
    try {
      await htmlFile.writeAsString(_buildPngHtml(svg, vb.$1, vb.$2),
          flush: true);
      final pngPath =
          '$outputDir${Platform.pathSeparator}图表${i + 1}.png';
      shot = await _edgeScreenshot(htmlPath, pngPath, vb.$1, vb.$2);
    } finally {
      try {
        if (await htmlFile.exists()) await htmlFile.delete();
      } catch (_) {}
    }
    if (shot) {
      okCount++;
    } else {
      errors.add('图表${i + 1}: 截图失败');
    }
  }
  if (okCount == 0) {
    return (false, errors.isEmpty ? '没有导出任何图表' : errors.join('；'));
  }
  final suffix =
      errors.isEmpty ? '' : '；${errors.length} 张失败（${errors.join('；')}）';
  return (true, '已导出 $okCount 张图表 PNG$suffix');
}

/// 渲染所有 Mermaid 图表为自包含 SVG 字符串，一次 Edge 进程。
///
/// 返回 `(是否成功, 提示消息, items)`；items 形如 `[{i, svg}]` 或 `[{i, error}]`，
/// 由 PNG 导出写文件。fatal（渲染初始化失败）直接返回失败。
Future<(bool, String, List<dynamic>)> _renderCharts(String markdown) async {
  final mermaidBlocks = <String>[];
  _extractMermaidBlocks(markdown, mermaidBlocks);
  if (mermaidBlocks.isEmpty) {
    return (false, '没有 Mermaid 图表', const []);
  }

  File? tempHtml;
  try {
    // 1. 内嵌 mermaid 库
    final mermaidJs =
        await rootBundle.loadString('assets/mermaid/mermaid.min.js');

    // 2. 组装自包含 HTML 并写临时文件
    final fullHtml = _buildSvgHtml(mermaidBlocks, mermaidJs);
    tempHtml = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'orbby_svg_${DateTime.now().millisecondsSinceEpoch}.html');
    await tempHtml.writeAsString(fullHtml, flush: true);

    // 3. 定位 Edge
    final edgePath = _findEdge();
    if (edgePath == null) {
      return (false, '未找到 Microsoft Edge', const []);
    }

    // 4. 无头模式 dump DOM（含渲染后的 svg 与 #orbby-svg-out 内容）
    //    多张图串行渲染，预算放宽到 30s 虚拟时间
    final process = await Process.start(edgePath, [
      '--headless',
      '--disable-gpu',
      '--virtual-time-budget=30000',
      '--dump-dom',
      tempHtml.path,
    ]);
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      process.kill();
      return (false, '导出超时，已终止', const []);
    }
    final dom = await stdoutFuture;
    final stderr = (await stderrFuture).trim();

    // 5. 提取注入脚本写入的结果（base64 编码的 JSON，避开 HTML 实体转义）
    final m =
        RegExp(r'<div id="orbby-svg-out">([A-Za-z0-9+/=]*)</div>')
            .firstMatch(dom);
    if (m == null) {
      final detail = stderr.isNotEmpty ? stderr : '未获取到图表 DOM';
      return (false,
          '图表生成失败（Edge 退出码 $exitCode${detail.isNotEmpty ? ': $detail' : ''}）',
          const []);
    }
    final List<dynamic> items;
    try {
      final jsonStr = utf8.decode(base64.decode(m.group(1)!.trim()));
      items = jsonDecode(jsonStr) as List;
    } catch (e) {
      return (false, '解析图表结果失败: $e', const []);
    }
    // 6. fatal（渲染初始化失败）直接报错
    for (final item in items.cast<Map<dynamic, dynamic>>()) {
      final fatal = item['fatal'];
      if (fatal != null) return (false, '渲染初始化失败: $fatal', const []);
    }
    return (true, '', items);
  } catch (e) {
    return (false, '导出失败: $e', const []);
  } finally {
    // 清理临时 HTML
    try {
      if (tempHtml != null && await tempHtml.exists()) {
        await tempHtml.delete();
      }
    } catch (_) {}
  }
}

/// 解析 SVG 字符串 viewBox 的宽高；解析失败返回 null。
(double, double)? _svgViewBox(String svg) {
  final m = RegExp(r'viewBox="[^"]*"').firstMatch(svg);
  if (m == null) return null;
  final parts = m
      .group(0)!
      .replaceAll('viewBox="', '')
      .replaceAll('"', '')
      .split(RegExp(r'[,\s]+'))
      .map(double.tryParse)
      .whereType<double>()
      .toList();
  if (parts.length < 4 || parts[2] <= 0 || parts[3] <= 0) return null;
  return (parts[2], parts[3]);
}

/// 组装 PNG 截图的临时 HTML：白底，SVG 按 viewBox 原尺寸渲染，四周留 padding。
String _buildPngHtml(String svg, double w, double h) {
  const pad = 20;
  // 显式覆盖 svg 宽高与 style，去掉 max-width 约束，按 viewBox 原尺寸渲染
  final sized = svg.replaceFirstMapped(
    RegExp(r'<svg\b[^>]*>'),
    (m) {
      var tag = m.group(0)!;
      tag = tag.replaceFirst(RegExp(r'width="[^"]*"'), 'width="$w"');
      tag = tag.replaceFirst(RegExp(r'height="[^"]*"'), 'height="$h"');
      tag = tag.replaceFirst(RegExp(r'style="[^"]*"'), '');
      if (!tag.contains('height=')) {
        tag = tag.replaceFirst(RegExp(r'>$'), ' height="$h">');
      }
      return tag;
    },
  );
  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:#fff;overflow:hidden;}</style>
</head>
<body>
<div style="padding:${pad}px;">
$sized
</div>
</body>
</html>''';
}

/// 用 Edge 无头模式把临时 HTML 截图成 PNG；窗口尺寸 = 图尺寸 + 四周留白。
Future<bool> _edgeScreenshot(
    String htmlPath, String pngPath, double w, double h) async {
  final edgePath = _findEdge();
  if (edgePath == null) return false;
  const pad = 20;
  final winW = (w + pad * 2).round().clamp(10, 10000);
  final winH = (h + pad * 2).round().clamp(10, 10000);
  final process = await Process.start(edgePath, [
    '--headless',
    '--disable-gpu',
    '--hide-scrollbars',
    '--default-background-color=FFFFFFFF',
    '--window-size=$winW,$winH',
    '--screenshot=$pngPath',
    htmlPath,
  ]);
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    process.kill();
    return false;
  }
  await stdoutFuture;
  await stderrFuture;
  if (exitCode != 0 || !await File(pngPath).exists()) return false;
  return await File(pngPath).length() > 0;
}

/// 组装 SVG 导出的自包含 HTML：内嵌 mermaid，用 `mermaid.render()` 逐个渲染。
///
/// `render()` 返回的 `result.svg` 自带完整主题样式（与预览区一致，不会因样式
/// 丢失而全黑），把前导的 `<style>` 挪进 `<svg>` 根内部，得到标准 SVG 文件。
/// 结果 JSON 写入 `#orbby-svg-out`，供 `--dump-dom` 输出后由 Flutter 端提取。
String _buildSvgHtml(List<String> mermaidBlocks, String mermaidJs) {
  // 图源码以 base64 内嵌进 JS。不能用 DOM 元素存源码：mermaid 渲染时会把
  // 主题样式注入到带 .mermaid class 的元素内部，之后读 textContent 会拿到
  // “CSS + 源码”混合，导致 render 解析失败。
  final sources = StringBuffer();
  for (final block in mermaidBlocks) {
    sources.writeln('"${base64Encode(utf8.encode(block))}",');
  }
  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
</head>
<body>
<script>
$mermaidJs
</script>
<script>
// 把计算样式内联到每个元素，摆脱对 <style> + class 选择器的依赖：
// 弱 CSS 的查看器（如 Windows 照片查看器）不应用 class 规则，若只靠
// <style> 会把所有元素渲染成默认黑色。
function inlineStyles(svg) {
  var props = ['fill','fill-opacity','stroke','stroke-opacity','stroke-width',
               'stroke-dasharray','stroke-linecap','stroke-linejoin',
               'color','opacity','font-family','font-size','font-weight','font-style',
               'stop-color','stop-opacity'];
  var els = svg.querySelectorAll('*');
  for (var k = 0; k < els.length; k++) {
    var el = els[k];
    var cs = window.getComputedStyle(el);
    var style = '';
    for (var p = 0; p < props.length; p++) {
      var val = cs.getPropertyValue(props[p]);
      if (val && val !== '' && val !== 'none' && val !== 'normal') {
        style += props[p] + ':' + val + ';';
      }
    }
    if (style) {
      var cur = el.getAttribute('style');
      el.setAttribute('style', (cur ? cur + ';' : '') + style);
    }
  }
}

function b64decode(b64) {
  var bin = atob(b64);
  var bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder('utf-8').decode(bytes);
}

// TextEncoder 把字符串编码为标准 UTF-8，非法/孤立代理字符替换为 U+FFFD，
// 不会抛错；避免 unescape+encodeURIComponent 链路产生孤立代理导致写出失败。
function toB64(str) {
  var bytes = new TextEncoder().encode(str);
  var bin = '';
  for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

// mermaid 生成的 svg 里偶尔带有孤立代理字符（如特殊符号），JSON 传输后会被
// 解码回孤立代理导致 UTF-8 写文件失败。这里把孤立代理替换为 U+FFFD。
function cleanSurrogates(s) {
  var out = '';
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      var c2 = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) { out += s[i] + s[i + 1]; i++; continue; }
      out += '�';
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      out += '�';
    } else {
      out += s[i];
    }
  }
  return out;
}

var sources = [
$sources];

var holder = document.createElement('div');
holder.id = 'orbby-holder';
holder.style.display = 'none';
document.body.appendChild(holder);

window.addEventListener('load', function () {
  try {
    mermaid.initialize({startOnLoad: false, theme: 'default', fontFamily: 'Microsoft YaHei', securityLevel: 'loose'});
    var out = [];
    (async function () {
      for (var i = 0; i < sources.length; i++) {
        try {
          holder.innerHTML = '';
          var result = await mermaid.render('mmd-' + i, b64decode(sources[i]));
          holder.innerHTML = result.svg;
          var svg = holder.querySelector('svg');
          if (!svg) {
            out.push({i: i, error: '未生成 SVG'});
            continue;
          }
          inlineStyles(svg);
          out.push({i: i,
              svg: cleanSurrogates(new XMLSerializer().serializeToString(svg))});
        } catch (e) {
          out.push({i: i, error: (e && e.message) ? e.message : String(e)});
        }
      }
      // base64 编码后写入，避免 HTML 序列化对 < & > 的转义干扰解析
      var payload = toB64(JSON.stringify(out));
      document.getElementById('orbby-svg-out').textContent = payload;
    })();
  } catch (e) {
    document.getElementById('orbby-svg-out').textContent =
        toB64(JSON.stringify({
          fatal: (e && e.message) ? e.message : String(e)
        }));
  }
});
</script>
<div id="orbby-svg-out"></div>
</body>
</html>''';
}

/// 从 markdown 源码中提取 ```mermaid 块，替换为占位符行。
///
/// [mermaidBlocks] 按出现顺序收集块内源码（不含围栏）。占位符用 **HTML 注释**
/// `<!--ORBBY_MERMAID_n-->`：markdown 不会对 HTML 注释做强调/转义处理，
/// 会被 markdownToHtml 原样保留，还原时可靠匹配（避免下划线被解析成粗体）。
String _extractMermaidBlocks(String markdown, List<String> mermaidBlocks) {
  final re = RegExp(r'```mermaid\s*\n([\s\S]*?)\n```');
  final buffer = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(markdown)) {
    buffer.write(markdown.substring(last, m.start));
    buffer.write('\n\n<!--ORBBY_MERMAID_${mermaidBlocks.length}-->\n\n');
    mermaidBlocks.add(m.group(1)!.trimRight());
    last = m.end;
  }
  buffer.write(markdown.substring(last));
  return buffer.toString();
}

/// 组装自包含 HTML：CSS 对齐预览区样式；有 mermaid 时内嵌库并初始化。
String _buildHtml(String body, String mermaidJs) {
  final mermaidInit = mermaidJs.isEmpty
      ? ''
      : '''
<script>
$mermaidJs
</script>
<script>
window.addEventListener('load', function () {
  mermaid.initialize({startOnLoad: false, theme: 'default', fontFamily: 'Microsoft YaHei', securityLevel: 'loose'});
  mermaid.run();
});
</script>
''';
  return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: 'Microsoft YaHei', sans-serif; color: #1F1F1F; margin: 24px; font-size: 13px; line-height: 1.7; }
  h1 { font-size: 22px; font-weight: 700; }
  h2 { font-size: 19px; font-weight: 600; }
  h3 { font-size: 16px; font-weight: 600; }
  h4 { font-size: 14px; font-weight: 600; }
  code { font-family: 'Cascadia Code', 'Consolas', monospace; background: #F0F2F5; color: #C7254E; padding: 1px 4px; border-radius: 3px; }
  pre { background: #F5F5F5; border: 1px solid #E0E0E0; border-radius: 8px; padding: 12px; overflow: auto; }
  pre code { background: none; color: #24292E; padding: 0; }
  blockquote { border-left: 3px solid #448AFF; background: #F0F5FF; margin: 8px 0; padding: 4px 12px; color: #6A737D; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border: 1px solid #E0E0E0; padding: 6px 10px; text-align: left; }
  th { background: #FAFAFA; font-weight: 600; text-align: center; }
  a { color: #448AFF; }
  img { max-width: 100%; }
  div.mermaid { text-align: center; margin: 12px 0; page-break-inside: avoid; }
  div.mermaid svg { max-width: 100%; height: auto; }
</style>
</head>
<body>
$body
$mermaidInit
</body>
</html>''';
}

/// 定位 Windows 自带的 Microsoft Edge。
String? _findEdge() {
  const candidates = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
