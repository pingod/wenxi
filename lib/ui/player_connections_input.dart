import 'package:flutter/material.dart';
import '../domain/playback.dart';
import 'player_theme.dart';

class PlayerConnectionsInput extends StatefulWidget {
  const PlayerConnectionsInput({
    super.key,
    required this.connections,
    required this.onApply,
  });
  final int connections;
  final Future<void> Function(int) onApply;

  @override
  State<PlayerConnectionsInput> createState() => _PlayerConnectionsInputState();
}

class _PlayerConnectionsInputState extends State<PlayerConnectionsInput> {
  late final input = TextEditingController(text: '${widget.connections}');
  String? error;
  bool busy = false;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> apply() async {
    if (busy) return;
    final value = int.tryParse(input.text.trim());
    if (value == null ||
        value < PlaybackPreferences.minConnections ||
        value > PlaybackPreferences.maxConnections) {
      setState(() {
        error =
            '请输入 ${PlaybackPreferences.minConnections} 至 '
            '${PlaybackPreferences.maxConnections} 之间的整数';
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onApply(value);
    } catch (_) {
      if (mounted) setState(() => error = '连接数设置失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('player-custom-connections'),
        controller: input,
        enabled: !busy,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: '自定义连接数',
          filled: true,
          fillColor: const Color(0xff25272d),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 18,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          helperText:
              '${PlaybackPreferences.minConnections}–'
              '${PlaybackPreferences.maxConnections} 个连接',
          errorText: error,
          labelStyle: const TextStyle(color: Colors.white70),
          helperStyle: const TextStyle(color: Colors.white60),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: playerAccent(context)),
          ),
        ),
        onChanged: (_) {
          if (error != null) setState(() => error = null);
        },
        onSubmitted: (_) => apply(),
      ),
      const SizedBox(height: 12),
      FilledButton(
        key: const Key('player-apply-custom-connections'),
        onPressed: busy ? null : apply,
        child: Text(busy ? '正在设置' : '应用连接数'),
      ),
    ],
  );
}
