import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'src/log_service.dart';

const kWindowTitle = 'Orbby MD Editor';

/// 初始窗口：宽 = 屏幕可见宽的 80%，高 = 屏幕可见高的 90%，跟随屏幕分辨率动态变化。
const kWidthFactor = 0.8;
const kHeightFactor = 0.9;
const kMinWidth = 640.0;
const kMinHeight = 400.0;

Future<void> main([List<String> args = const <String>[]]) async {
  WidgetsFlutterBinding.ensureInitialized();

  await LogService.init();
  await windowManager.ensureInitialized();

  await _configureWindow();
  // Windows 文件关联会把被双击的文件路径作为启动参数传入。
  String? initialFilePath;
  for (final arg in args) {
    final lower = arg.toLowerCase();
    if (arg.trim().isNotEmpty &&
        (lower.endsWith('.md') ||
            lower.endsWith('.markdown') ||
            lower.endsWith('.txt'))) {
      initialFilePath = arg;
      break;
    }
  }
  runApp(MarkdownViewerApp(initialFilePath: initialFilePath));
}

/// 无边框窗口：宽 1400，高 = 屏幕可见高 × 80%（clamp 到最小 400），居中显示。
Future<void> _configureWindow() async {
  final display = await screenRetriever.getPrimaryDisplay();
  final screenSize = display.visibleSize ?? display.size;

  var width = screenSize.width * kWidthFactor;
  var height = screenSize.height * kHeightFactor;
  if (width < kMinWidth) width = kMinWidth;
  if (height < kMinHeight) height = kMinHeight;
  if (width > screenSize.width) width = screenSize.width;
  if (height > screenSize.height) height = screenSize.height;

  final left = (screenSize.width - width) / 2;
  final top = (screenSize.height - height) / 2;

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(width, height),
      center: true,
      backgroundColor: Colors.transparent,
      title: kWindowTitle,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setMinimumSize(const Size(kMinWidth, kMinHeight));
      await windowManager.setPosition(Offset(left, top));
      await windowManager.setTitle(kWindowTitle);
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
