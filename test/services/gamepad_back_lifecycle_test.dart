import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

void main() {
  testWidgets('unhandled B release pops the current route once', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
        },
        home: const Text('home'),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Focus(autofocus: true, child: Text('detail'))),
    );
    await tester.pumpAndSettle();
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    GamepadButtonEvent button(bool pressed) => GamepadButtonEvent(
      gamepadId: 1,
      timestamp: 0,
      button: GamepadButton.b,
      pressed: pressed,
      value: pressed ? 1 : 0,
    );
    service.debugHandleGamepadEvent(button(true));
    await tester.pump();
    expect(find.text('detail'), findsOneWidget);
    service.debugHandleGamepadEvent(button(false));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
  for (final handledOnDown in [true, false]) {
    testWidgets('focused B handler prevents fallback (down=$handledOnDown)', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          shortcuts: {
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
          },
          home: const Text('home'),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event.logicalKey != LogicalKeyboardKey.gameButtonB) return KeyEventResult.ignored;
              if ((event is KeyDownEvent) == handledOnDown) {
                calls++;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: const Text('detail'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
      for (final pressed in [true, false]) {
        service.debugHandleGamepadEvent(
          GamepadButtonEvent(
            gamepadId: 1,
            timestamp: 0,
            button: GamepadButton.b,
            pressed: pressed,
            value: pressed ? 1 : 0,
          ),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('detail'), findsOneWidget);
    });
  }

  testWidgets('unhandled B dismisses only the top modal', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
        },
        home: const Text('home'),
      ),
    );
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('detail')));
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('modal')),
      ),
    );
    await tester.pumpAndSettle();
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    for (final pressed in [true, false]) {
      service.debugHandleGamepadEvent(
        GamepadButtonEvent(
          gamepadId: 1,
          timestamp: 0,
          button: GamepadButton.b,
          pressed: pressed,
          value: pressed ? 1 : 0,
        ),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('modal'), findsNothing);
    expect(find.text('detail'), findsOneWidget);
  });

  testWidgets('disconnect while holding B does not pop', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
        },
        home: const Text('home'),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Focus(autofocus: true, child: Text('detail'))),
    );
    await tester.pumpAndSettle();
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    service.debugHandleGamepadEvent(
      GamepadButtonEvent(gamepadId: 1, timestamp: 0, button: GamepadButton.b, pressed: true, value: 1),
    );
    await tester.pump();
    service.debugHandleGamepadEvent(
      GamepadConnectionEvent(
        gamepadId: 1,
        timestamp: 0,
        connected: false,
        info: const GamepadInfo(id: 1, name: 'Test Pad'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
  });

  testWidgets('B triggers back on release, not press', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event.logicalKey == LogicalKeyboardKey.gameButtonB && event is KeyUpEvent) backs++;
            return KeyEventResult.handled;
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    GamepadButtonEvent button(bool pressed) => GamepadButtonEvent(
      gamepadId: 1,
      timestamp: 0,
      button: GamepadButton.b,
      pressed: pressed,
      value: pressed ? 1 : 0,
    );
    service.debugHandleGamepadEvent(button(true));
    await tester.pump();
    expect(backs, 0);
    service.debugHandleGamepadEvent(button(false));
    await tester.pump();
    expect(backs, 1);
  });
}
