import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'log_service.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

/// 渲染单个 Mermaid 代码块的 WebView2 封装。
///
/// 原理：加载本地打包的 mermaid.min.js（esbuild IIFE，须用普通 `<script>`
/// 加载，执行后挂到 `window.mermaid`），通过 `mermaid.render()` 把源码渲染为
/// SVG 注入页面。内容更新走 `executeScript` 只刷新 SVG，不重建 WebView。
///
/// 使用 [WebviewController]（webview_flutter_windows 独立 API，非
/// webview_flutter 的 platform_interface 实现），避免后者在 Windows 上
/// 无平台实现的问题。
class MermaidView extends StatefulWidget {
  const MermaidView({super.key, required this.source});

  final String source;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView>
    with AutomaticKeepAliveClientMixin {
  static const _bgColor = Colors.white;

  /// 让图滚出屏幕后 State 保持存活，避免 ListView 懒加载销毁重建 WebView。
  @override
  bool get wantKeepAlive => true;

  /// 虚拟主机名 → 打包的 assets/mermaid 目录，WebView2 直接从磁盘读库。
  static const _mermaidHost = 'mermaid.local';

  /// flutter_assets 磁盘根路径，全局只解析一次。
  static String? _assetsRoot;

  /// source → 用户手动调整过的缩放比例。只有手动调整才缓存；自动适配结果
  /// 不缓存，这样 WebView 重建后仍能按图内容重新适配。
  static final Map<String, double> _zoomCache = {};

  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _debounce;
  double _contentHeight = 300;
  bool _ready = false;
  bool _webviewInitialized = false;
  String? _initError;
  /// -1 = 缩放未定，由 JS 端按图内容自动计算；>0 = 具体缩放比例。
  double _zoom = -1;
  /// 是否被用户手动调整过（Ctrl+滚轮 / 缩放条）。自动适配结果不视为手动，
  /// 这样图翻页回来后仍能按内容重新适配。
  bool _userAdjusted = false;

  @override
  void initState() {
    super.initState();
    _loadZoomFromCache();
    _init();
  }

  @override
  void dispose() {
    if (_userAdjusted) {
      _zoomCache[widget.source] = _zoom;
    }
    _debounce?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MermaidView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source) {
      _loadZoomFromCache();
      _scheduleRender();
    }
  }

  /// 从缓存恢复手动缩放；没有缓存则交给 JS 端按内容自动适配。
  void _loadZoomFromCache() {
    final cached = _zoomCache[widget.source];
    _userAdjusted = cached != null;
    _zoom = cached ?? -1;
  }

  Future<void> _init() async {
    try {
      // 页面导航完成后执行一次渲染（HTML 内脚本只定义渲染函数，不自动调用）
      _subs.add(_controller.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) {
          _renderCurrent();
        }
      }));
      // JS 通过 window.chrome.webview.postMessage 上报高度或缩放变化
      _subs.add(
          _controller.webMessage.listen((msg) => _onWebMessage(msg)));

      await _controller.initialize();
      _webviewInitialized = true;

      // 把打包的 assets/mermaid 映射到虚拟域名，HTML 用普通 script 标签从
      // 磁盘加载库，避免把 3.5MB 的 base64 塞进 HTML 导致 NavigateToString 白屏。
      final assetsRoot = await _resolveAssetsRoot();
      if (!mounted) return;
      await _controller.addVirtualHostNameMapping(
        _mermaidHost,
        '$assetsRoot${Platform.pathSeparator}assets'
            '${Platform.pathSeparator}mermaid',
        WebviewHostResourceAccessKind.allow,
      );
      await _controller.loadStringContent(_htmlTemplate);

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      LogService.error('MermaidView 初始化失败', exception: e, category: 'system');
      if (mounted) setState(() => _initError = '$e');
    }
  }

  /// 定位打包后的 flutter_assets 目录（exe 同级 data/flutter_assets）。
  /// static 缓存避免重复解析磁盘路径。
  static Future<String> _resolveAssetsRoot() async {
    final cached = _assetsRoot;
    if (cached != null) return cached;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final root = '$exeDir${Platform.pathSeparator}data'
        '${Platform.pathSeparator}flutter_assets';
    if (!Directory(root).existsSync()) {
      throw StateError('未找到 flutter_assets 目录: $root');
    }
    _assetsRoot = root;
    return root;
  }

  void _scheduleRender() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _renderCurrent);
  }

  void _renderCurrent() {
    if (!_webviewInitialized) return;
    final b64 = base64Encode(utf8.encode(widget.source));
    // 未手动调整时使用 80% 默认缩放；已有手动缩放值保持不变。
    final target = _userAdjusted ? _zoom : 0.8;
    try {
      _controller.executeScript(
          "window.__targetScale = $target; window.__renderMermaid('$b64');");
    } catch (e) {
      LogService.error('MermaidView 执行渲染 JS 失败', exception: e, category: 'system');
    }
  }

  void _onWebMessage(dynamic msg) {
    final s = '$msg';
    // JS 按图内容自动算出的默认缩放，只同步显示，不视为手动调整
    if (s.startsWith('__autoZoom:')) {
      final z = double.tryParse(s.substring(11));
      if (z == null || !mounted || z == _zoom) return;
      setState(() => _zoom = z);
      return;
    }
    // Ctrl+滚轮缩放后，JS 用 __zoom:N 前缀同步缩放比例
    if (s.startsWith('__zoom:')) {
      final z = double.tryParse(s.substring(7));
      if (z == null || !mounted || z == _zoom) return;
      _userAdjusted = true;
      setState(() => _zoom = z);
      return;
    }
    _onHeightChanged(s);
  }

  void _onHeightChanged(String msg) {
    final height = double.tryParse(msg);
    if (height == null || !mounted || height == _contentHeight) return;
    setState(() => _contentHeight = height);
  }

  static const _minZoom = 0.35;
  static const _maxZoom = 3.0;

  void _changeZoom(double delta) {
    if (!_webviewInitialized) return;
    // _zoom 还没同步到自动值时，按 100% 起步
    final base = _zoom > 0 ? _zoom : 1.0;
    final next = (base + delta).clamp(_minZoom, _maxZoom).toDouble();
    if (next == _zoom) return;
    _userAdjusted = true;
    setState(() => _zoom = next);
    _executeZoom(next);
  }

  /// 重置 = 清除手动调整与缓存，回到 JS 端按图内容重新自动适配。
  void _resetZoom() {
    if (!_webviewInitialized) return;
    _userAdjusted = false;
    _zoomCache.remove(widget.source);
    setState(() => _zoom = -1);
    try {
      _controller.executeScript('window.__setAutoZoom();');
    } catch (e) {
      LogService.error('MermaidView 重置缩放失败', exception: e, category: 'system');
    }
  }

  void _executeZoom(double zoom) {
    try {
      _controller.executeScript('window.__setZoom($zoom);');
    } catch (e) {
      LogService.error('MermaidView 设置缩放失败', exception: e, category: 'system');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_initError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Mermaid 渲染初始化失败（请确认 WebView2 运行时已安装）\n$_initError',
          style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12),
        ),
      );
    }
    if (!_ready) {
      return const SizedBox(height: 300);
    }
    return SizedBox(
      width: double.infinity,
      height: _contentHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Webview(_controller),
            ),
          ),
        ],
      ),
    );
  }
}

/// 悬浮在图右上角的缩放控制条：放大 / 缩小 / 重置。
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.zoom_out, tooltip: '缩小', onPressed: onZoomOut),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              zoom > 0 ? '${(zoom * 100).round()}%' : '自动',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
          _ZoomBtn(icon: Icons.zoom_in, tooltip: '放大', onPressed: onZoomIn),
          _ZoomBtn(icon: Icons.restart_alt, tooltip: '重置', onPressed: onReset),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: Colors.white),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      splashRadius: 14,
    );
  }
}

const _htmlTemplate = r'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  html, body {
    margin:0;
    padding:0;
    background-color:#ffffff;
    overflow:hidden;
    user-select:text;
    -webkit-user-select:text;
  }
  #diagram { display:flex; justify-content:center; padding:12px; box-sizing:border-box; }
  #diagram svg {
    max-width:100%;
    height:auto;
    display:block;
    user-select:text;
    -webkit-user-select:text;
  }
  #diagram text,
  #diagram foreignObject,
  #diagram foreignObject * {
    user-select:text;
    -webkit-user-select:text;
  }
  /* 流程图统一为浅色画布、彩色节点和直角连线。 */
  #diagram svg[aria-roledescription="flowchart"] .node rect,
  #diagram svg[aria-roledescription="flowchart"] .node polygon,
  #diagram svg[aria-roledescription="flowchart"] .node circle {
    stroke-width:1.5px;
  }
  #diagram svg[aria-roledescription="flowchart"] .node.start rect,
  #diagram svg[aria-roledescription="flowchart"] .node.start polygon {
    fill:#FFF1B8 !important;
    stroke:#F5B800 !important;
  }
  #diagram svg[aria-roledescription="flowchart"] .node.process rect,
  #diagram svg[aria-roledescription="flowchart"] .node.process polygon {
    fill:#DDE9FF !important;
    stroke:#5287FF !important;
  }
  #diagram svg[aria-roledescription="flowchart"] .node.decision rect,
  #diagram svg[aria-roledescription="flowchart"] .node.decision polygon {
    fill:#FFD9F0 !important;
    stroke:#E83DB8 !important;
  }
  #diagram svg[aria-roledescription="flowchart"] .node.document rect,
  #diagram svg[aria-roledescription="flowchart"] .node.document polygon,
  #diagram svg[aria-roledescription="flowchart"] .node.document path {
    fill:#FFE0DC !important;
    stroke:#FF806D !important;
  }
  #diagram svg[aria-roledescription="flowchart"] .edgePath .path {
    stroke:#222222;
    stroke-width:1.2px;
  }
  #diagram svg[aria-roledescription="flowchart"] .arrowheadPath {
    fill:#222222;
    stroke:#222222;
  }
  #diagram svg[aria-roledescription="flowchart"] .edgeLabel rect {
    fill:#ffffff;
    opacity:.96;
  }
  #diagram svg[aria-roledescription="flowchart"] .edgeLabel text,
  #diagram svg[aria-roledescription="flowchart"] .nodeLabel {
    fill:#222222;
    color:#222222;
    font-family:'Microsoft YaHei', sans-serif;
  }
  .err { color:#ff6b6b; font-family:Consolas,monospace; font-size:13px; white-space:pre-wrap; word-break:break-all; }
</style>
</head>
<body>
<div id="diagram"></div>
<script src="https://mermaid.local/mermaid.min.js"></script>
<script>
(function() {
  if (typeof mermaid === 'undefined') {
    var el0 = document.getElementById('diagram');
    el0.innerHTML = '<div class="err">Mermaid 库加载失败</div>';
    window.chrome.webview.postMessage(String(el0.scrollHeight || 300));
    return;
  }
  mermaid.initialize({
    startOnLoad: false,
    theme: 'default',
    securityLevel: 'loose',
    fontFamily: 'Microsoft YaHei',
    themeVariables: {
      background: '#ffffff',
      primaryColor: '#DDE9FF',
      primaryTextColor: '#222222',
      primaryBorderColor: '#5287FF',
      secondaryColor: '#FFF1B8',
      secondaryTextColor: '#222222',
      secondaryBorderColor: '#F5B800',
      tertiaryColor: '#FFD9F0',
      tertiaryTextColor: '#222222',
      tertiaryBorderColor: '#E83DB8',
      lineColor: '#222222',
      textColor: '#222222',
      nodeBorder: '#5287FF',
      clusterBkg: '#F8FAFF',
      clusterBorder: '#B8C8F5',
      edgeLabelBackground: '#ffffff'
    },
    flowchart: {
      curve: 'linear',
      nodeSpacing: 50,
      rankSpacing: 60,
      htmlLabels: true
    }
  });

  // 图适应容器宽度后的实际显示宽度 / viewBox 自然宽度 / 按内容自动适配的比例
  var _fitW = 0;
  var _naturalW = 0;
  var _fitScale = 0.5;
  var _minScale = 0.35;
  function _postHeight() {
    var el = document.getElementById('diagram');
    window.chrome.webview.postMessage(String(el.scrollHeight || el.offsetHeight || 300));
  }

  // 缩放：scale 是相对图自然宽的比例（1 = 原始尺寸）。不超过容器宽时居中
  // 完整显示、无滚动条；放大超过容器宽才放开滚动以查看细节。
  window.__setZoom = function(scale) {
    window.__currentScale = scale;
    var svg = document.querySelector('#diagram svg');
    if (!svg || !_naturalW) {
      _postHeight();
      return;
    }
    var html = document.documentElement;
    // 放大超过容器宽度才开滚动看细节；适应/缩小时居中完整显示
    var fits = Math.round(_naturalW * scale) <=
        (document.getElementById('diagram').clientWidth + 1);
    html.style.overflow = fits ? 'hidden' : 'auto';
    document.body.style.overflow = fits ? 'hidden' : 'auto';
    svg.style.maxWidth = 'none';
    svg.style.width = Math.round(_naturalW * scale) + 'px';
    svg.style.height = 'auto';
    _postHeight();
  };

  // 回到按图内容自动适配的默认缩放（重置按钮）
  window.__setAutoZoom = function() {
    if (!_fitScale) return;
    __setZoom(_fitScale);
    window.chrome.webview.postMessage('__autoZoom:' + Math.round(_fitScale * 100));
  };

  // Ctrl+滚轮 → 统一走 __setZoom，preventDefault 阻止页面滚动和 WebView2 内置
  // 缩放；普通滚轮放行，保留图放大后的内部滚动。
  document.addEventListener('wheel', function(e) {
    if (!e.ctrlKey) return;
    e.preventDefault();
    var cur = window.__currentScale || _fitScale;
    var next = Math.min(3, Math.max(_minScale, cur + (e.deltaY < 0 ? 0.2 : -0.2)));
    __setZoom(next);
    window.chrome.webview.postMessage('__zoom:' + Math.round(next * 100));
  }, { passive: false });

  window.__renderMermaid = async function(b64code) {
    var el = document.getElementById('diagram');
    try {
      var bin = atob(b64code);
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      var code = new TextDecoder('utf-8').decode(bytes);
      var result = await mermaid.render('mmd-' + Date.now(), code);
      el.innerHTML = result.svg;
      // 去掉 mermaid 内联的固定 max-width，让 SVG 按容器宽度等比缩放、完整显示
      var svg = el.querySelector('svg');
      if (svg) {
        svg.removeAttribute('style');
        svg.setAttribute('style',
            'max-width:100%;height:auto;display:block;');
        // 自然宽度优先取 viewBox，退化用实际渲染宽度
        var vbW = 0;
        var vb = svg.getAttribute('viewBox');
        if (vb) {
          var parts = vb.trim().split(/[\s,]+/).map(Number);
          if (parts.length >= 4 && isFinite(parts[2])) vbW = parts[2];
        }
        _fitW = svg.getBoundingClientRect().width || 0;  // 适应容器后的宽度
        _naturalW = vbW > 0 ? vbW : _fitW;
        // 自动适配：小图原尺寸（1.0），大图缩到刚好适应容器宽，保底可读
        _fitScale = _naturalW > 0
            ? Math.max(_minScale, Math.min(1, _fitW / _naturalW))
            : 1;
      }
    } catch (e) {
      el.innerHTML = '<div class="err">Mermaid 渲染失败:\n' +
          (e && e.message ? e.message : String(e)) + '</div>';
    }
    // 应用缩放：Flutter 端手动调整过就恢复其值，否则按图内容自动适配
    var target = (window.__targetScale && window.__targetScale > 0)
        ? window.__targetScale : _fitScale;
    __setZoom(target);
    if (!(window.__targetScale && window.__targetScale > 0)) {
      // 自动适配结果同步给 Flutter（不标记为手动调整）
      window.chrome.webview.postMessage('__autoZoom:' + Math.round(_fitScale * 100));
    }
  };
})();
</script>
</body>
</html>''';
