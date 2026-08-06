import 'package:flutter/material.dart';

import 'src/markdown_viewer_screen.dart';

class MarkdownViewerApp extends StatelessWidget {
  const MarkdownViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Microsoft YaHei'),
      home: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: const MarkdownViewerScreen(),
      ),
    );
  }
}
