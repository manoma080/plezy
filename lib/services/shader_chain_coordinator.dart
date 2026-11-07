import '../mpv/player/player.dart';

/// Serializes shader transactions issued by Plezy services for one player.
class ShaderChainCoordinator {
  ShaderChainCoordinator._(this.player);
  static final Expando<ShaderChainCoordinator> _instances = Expando();
  static ShaderChainCoordinator forPlayer(Player player) => _instances[player] ??= ShaderChainCoordinator._(player);

  final Player player;
  Future<void> _pending = Future.value();
  final Set<String> _owned = {};
  bool _uncertain = false;

  /// Check before staging files so a quarantined player cannot leak more files.
  void ensureCertain() {
    if (_uncertain) throw StateError('Shader chain state is uncertain; refusing further changes');
  }

  /// Retain staged files when a failed update might have exposed their paths.
  void quarantine() => _uncertain = true;

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Never reconstruct the lossy string representation of mpv's list.
  /// All removals are restricted to paths previously installed by this object.
  Future<void> replace({required Iterable<String> remove, required Iterable<String> add}) async {
    if (_uncertain) throw StateError('Shader chain state is uncertain; refusing further changes');
    final old = remove.toList();
    final next = add.toList();
    if (old.toSet().length != old.length ||
        next.toSet().length != next.length ||
        old.any((p) => p.isEmpty || !_owned.contains(p)) ||
        next.any((p) => p.isEmpty)) {
      throw StateError('Ambiguous shader ownership');
    }
    if (old.length == next.length && List.generate(old.length, (i) => old[i] == next[i]).every((v) => v)) return;
    final raw = await player.getProperty('glsl-shaders');
    if (raw == null) throw StateError('Cannot inspect shader collisions');
    // Substring checks intentionally err on the side of rejecting ambiguous
    // paths. A string snapshot cannot prove identity or detect all races.
    for (final p in {...old, ...next}) {
      final count = p.allMatches(raw).length;
      if (_owned.contains(p) ? count != 1 : count != 0) {
        throw StateError('Possible shader path collision: $p');
      }
      if (_owned.contains(p) && !old.contains(p)) throw StateError('Shader belongs to another operation');
    }
    final fresh = next.where((p) => !old.contains(p)).toList();
    final retained = next.where(old.contains).toList();
    if (next.join('\u0000') != [...fresh, ...retained].join('\u0000')) {
      throw StateError('Cannot safely achieve requested shader order');
    }
    if (fresh.isEmpty &&
        retained.isNotEmpty &&
        old.where(retained.contains).join('\u0000') != retained.join('\u0000')) {
      throw StateError('Cannot safely reorder shader paths without a replacement');
    }
    final toRemove = fresh.isEmpty ? old.where((p) => !retained.contains(p)).toList() : old;
    final toReappend = fresh.isEmpty ? <String>[] : retained;
    final appended = <String>[];
    final removed = <String>[];
    try {
      for (final p in fresh) {
        await player.command(['change-list', 'glsl-shaders', 'append', p]);
        appended.add(p);
      }
      // Removing from the end permits exact compensation for the usual
      // contiguous owned suffix without moving the remaining owned entries.
      for (final p in toRemove.reversed) {
        await player.command(['change-list', 'glsl-shaders', 'remove', p]);
        removed.add(p);
      }
      for (final p in toReappend) {
        await player.command(['change-list', 'glsl-shaders', 'append', p]);
        appended.add(p);
      }
      _owned.removeAll(old);
      _owned.addAll(next);
    } catch (error, stack) {
      // A failed command may have taken effect despite the error, so do not
      // continue with potentially ambiguous ownership even if compensation works.
      _uncertain = true;
      try {
        for (final p in appended.reversed) {
          await player.command(['change-list', 'glsl-shaders', 'remove', p]);
        }
        for (final p in removed.reversed) {
          await player.command(['change-list', 'glsl-shaders', 'append', p]);
        }
      } catch (_) {
        // Preserve the original error; state remains quarantined.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
}
