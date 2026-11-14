import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

void main() {
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
