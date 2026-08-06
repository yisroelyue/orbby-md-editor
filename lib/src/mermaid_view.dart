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

  /// source → 最近一次缩放比例。flutter_markdown 用 ListView 懒加载，图滚出
  /// 屏幕 State 会被销毁、滚回来重建 WebView，用缓存恢复上次缩放。
  static final Map<String, double> _zoomCache = {};

  final WebviewController _controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _debounce;
  double _contentHeight = 300;
  bool _ready = false;
  bool _webviewInitialized = false;
  String? _initError;
  double _zoom = 0.5;

  @override
  void initState() {
    super.initState();
    _zoom = _zoomCache[widget.source] ?? 0.5;
    _init();
  }

  @override
  void dispose() {
    _zoomCache[widget.source] = _zoom;
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
      _zoom = _zoomCache[widget.source] ?? 0.5;
      _scheduleRender();
    }
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
    try {
      _controller.executeScript(
          "window.__targetScale = $_zoom; window.__renderMermaid('$b64');");
    } catch (e) {
      LogService.error('MermaidView 执行渲染 JS 失败', exception: e, category: 'system');
    }
  }

  void _onWebMessage(dynamic msg) {
    final s = '$msg';
    // Ctrl+滚轮缩放后，JS 用 __zoom:N 前缀同步缩放比例
    if (s.startsWith('__zoom:')) {
      final z = double.tryParse(s.substring(7));
      if (z == null || !mounted || z == _zoom) return;
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

  static const _minZoom = 0.3;
  static const _maxZoom = 3.0;

  void _changeZoom(double delta) {
    if (!_webviewInitialized) return;
    final next = (_zoom + delta).clamp(_minZoom, _maxZoom).toDouble();
    if (next == _zoom) return;
    setState(() => _zoom = next);
    _executeZoom(next);
  }

  void _resetZoom() {
    if (!_webviewInitialized || _zoom == 1.0) return;
    setState(() => _zoom = 1.0);
    _executeZoom(1.0);
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
      height: _contentHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Webview(_controller),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _ZoomBar(
              zoom: _zoom,
              onZoomIn: () => _changeZoom(0.2),
              onZoomOut: () => _changeZoom(-0.2),
              onReset: _resetZoom,
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
              '${(zoom * 100).round()}%',
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
  html, body { margin:0; padding:0; background:#ffffff; overflow:hidden; }
  #diagram { display:flex; justify-content:center; padding:12px; box-sizing:border-box; }
  #diagram svg { max-width:100% !important; height:auto !important; display:block; }
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
    fontFamily: 'Microsoft YaHei'
  });

  // SVG 适应宽度后的基准宽度 + 高度上报（__setZoom 复用）
  var _baseW = 0;
  // 默认缩放比例：每次渲染完成后自动应用
  var _defaultScale = 0.5;
  function _postHeight() {
    var el = document.getElementById('diagram');
    window.chrome.webview.postMessage(String(el.scrollHeight || el.offsetHeight || 300));
  }

  // 缩放：scale=1 回到适应宽度（无滚动条）；>1 放大并放开滚动以查看细节
  window.__setZoom = function(scale) {
    window.__currentScale = scale;
    var svg = document.querySelector('#diagram svg');
    if (!svg || !_baseW) return;
    var html = document.documentElement;
    if (scale > 1.001) {
      html.style.overflow = 'auto';
      document.body.style.overflow = 'auto';
    } else {
      html.style.overflow = 'hidden';
      document.body.style.overflow = 'hidden';
    }
    if (Math.abs(scale - 1) <= 0.001) {
      // 重置：回到适应宽度
      svg.style.maxWidth = '100%';
      svg.style.width = '';
      svg.style.height = 'auto';
    } else {
      // 缩小或放大：按基准宽度乘比例
      svg.style.maxWidth = 'none';
      svg.style.width = Math.round(_baseW * scale) + 'px';
      svg.style.height = 'auto';
    }
    _postHeight();
  };

  // Ctrl+滚轮 → 统一走 __setZoom，preventDefault 阻止页面滚动和 WebView2 内置
  // 缩放；普通滚轮放行，保留图放大后的内部滚动。
  document.addEventListener('wheel', function(e) {
    if (!e.ctrlKey) return;
    e.preventDefault();
    var cur = window.__currentScale || _defaultScale;
    var next = Math.min(3, Math.max(0.3, cur + (e.deltaY < 0 ? 0.2 : -0.2)));
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
        _baseW = svg.getBoundingClientRect().width || 0;
      }
    } catch (e) {
      el.innerHTML = '<div class="err">Mermaid 渲染失败:\n' +
          (e && e.message ? e.message : String(e)) + '</div>';
    }
    // 应用缩放：优先用 Flutter 端设置的 __targetScale（翻页重建后恢复上次缩放），
    // 否则用默认 _defaultScale（=50%）
    var target = (window.__targetScale && window.__targetScale > 0)
        ? window.__targetScale : _defaultScale;
    if (Math.abs(target - 1) > 0.001) {
      __setZoom(target);   // 应用缩放，内部会上报高度
    } else {
      _postHeight();
    }
  };
})();
</script>
</body>
</html>''';
