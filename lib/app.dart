import 'package:flutter/material.dart';

import 'src/markdown_viewer_screen.dart';

class MarkdownViewerApp extends StatelessWidget {
  const MarkdownViewerApp({super.key, this.initialFilePath});

  final String? initialFilePath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Microsoft YaHei'),
      home: Padding(
        // 为阴影预留透明空间；窗口本身是透明的无边框窗口。
        padding: const EdgeInsets.all(12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 22,
                spreadRadius: 2,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: MarkdownViewerScreen(initialFilePath: initialFilePath),
          ),
        ),
      ),
    );
  }
}
