import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

void main() {
  testWidgets('controllers latch independently and resist threshold chatter', (tester) async {
    final directions = <TraversalDirection>[];
    final owner = Object();
    GamepadService.registerRightStickSeek(owner, onSeek: directions.add, isActive: () => true);
    addTearDown(() => GamepadService.unregisterRightStickSeek(owner));
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    void axis(int id, double value) => service.debugHandleGamepadEvent(
      GamepadAxisEvent(gamepadId: id, timestamp: 0, axis: GamepadAxis.rightStickX, value: value),
    );
    axis(1, 0.8);
    axis(1, 0.49);
    axis(1, 0.8);
    expect(directions, [TraversalDirection.right]);
    axis(2, 0.8);
    expect(directions, [TraversalDirection.right, TraversalDirection.right]);
    axis(1, 0.0);
    axis(1, 0.8);
    expect(directions, [TraversalDirection.right, TraversalDirection.right, TraversalDirection.right]);
  });

  testWidgets('right stick seeks horizontally once per deflection and ignores vertical', (tester) async {
    final directions = <TraversalDirection>[];
    final owner = Object();
    GamepadService.registerRightStickSeek(owner, onSeek: directions.add, isActive: () => true);
    addTearDown(() => GamepadService.unregisterRightStickSeek(owner));
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));
    for (final axis in [GamepadAxis.rightStickX, GamepadAxis.rightStickY]) {
      for (final value in [-1.0, 1.0]) {
        for (final v in [value, value, 0.0]) {
          service.debugHandleGamepadEvent(GamepadAxisEvent(gamepadId: 1, timestamp: 0, axis: axis, value: v));
        }
      }
    }
    expect(directions, [TraversalDirection.left, TraversalDirection.right]);
  });
}
