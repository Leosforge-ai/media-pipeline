import 'package:flutter/material.dart';

class MediaPipelineApp extends StatelessWidget {
  const MediaPipelineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Media Pipeline',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6f73),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
      ),
      home: const Scaffold(
        body: Center(child: Text('Media Pipeline desktop shell')),
      ),
    );
  }
}
