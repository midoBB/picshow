import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'gallery_demo_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const MyApp());
}

final GoRouter _router = GoRouter(
  initialLocation: DemoGalleryScreen.path,
  routes: [
    GoRoute(
      path: DemoGalleryScreen.path,
      builder: (context, state) => const DemoGalleryScreen(),
    ),
  ],
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'KGallery Telegram Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
