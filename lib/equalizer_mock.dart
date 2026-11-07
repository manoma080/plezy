// Standalone development entry point: flutter build apk --debug -t lib/equalizer_mock.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'mpv/mpv.dart';
import 'services/settings_service.dart';
import 'services/video_equalizer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsService.getInstance();
  runApp(MaterialApp(home: MockPlayer(settings: settings)));
}

class MockPlayer extends StatefulWidget {
  const MockPlayer({super.key, required this.settings});
  final SettingsService settings;
  @override
  State<MockPlayer> createState() => _MockPlayerState();
}

class _MockPlayerState extends State<MockPlayer> {
  final player = Player(useExoPlayer: false);
  late final equalizer = VideoEqualizer.forPlayer(
    player,
    read: (key) => widget.settings.readInt(key),
    write: widget.settings.writeInt,

  );
  String status = 'Opening';
  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> logRoute(String label) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final hwdec = await player.getProperty('hwdec-current');
    final vo = await player.getProperty('current-vo');
    final pause = await player.getProperty('pause');
    debugPrint('MOCK_ROUTE $label hwdec-current=$hwdec current-vo=$vo pause=$pause');
  }

  Future<void> start() async {
    try {
      await player.setProperty(
        'hwdec',
        const String.fromEnvironment('MOCK_HWDEC', defaultValue: 'mediacodec,mediacodec-copy'),
      );
      await equalizer.restore();
      await player.setProperty('loop-file', 'inf');
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/equalizer-sample.mp4');
      final sample = await rootBundle.load('assets/equalizer-sample.mp4');
      await file.writeAsBytes(sample.buffer.asUint8List(sample.offsetInBytes, sample.lengthInBytes));
      await player.open(Media(file.path));
      await logRoute('opened');
      if (mounted) setState(() => status = 'Playing');
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(title: Text('Filter mock: $status')),
    body: Column(
      children: [
        SizedBox(height: 240, child: Video(player: player)),
        TextButton(
          onPressed: () async {
            await player.playOrPause();
            await logRoute('pause/play');
          },
          child: const Text('Pause / play'),
        ),
        Expanded(
          child: ColoredBox(
            color: Colors.white,
            child: ListView(
              children: [
                for (final control in VideoEqualizerControl.values)
                  Column(
                    children: [
                      Text('${control.name}: ${equalizer.value(control)}'),
                      Slider(
                        value: equalizer.value(control).toDouble(),
                        min: -control.bound.toDouble(),
                        max: control.bound.toDouble(),
                        divisions: control.bound * 2,
                        onChanged: (value) async {
                          await equalizer.set(control, value.round());
                          if (mounted) setState(() {});
                        },
                        onChangeEnd: (value) {
                          logRoute('${control.name}=${value.round()}');
                        },
                      ),
                    ],
                  ),
                TextButton(
                  onPressed: () async {
                    await equalizer.reset();
                    if (mounted) setState(() {});
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
