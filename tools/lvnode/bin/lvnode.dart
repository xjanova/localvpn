import 'dart:io';

import 'package:lvnode/lvnode.dart';

/// `lvnode` — runs under systemd with /etc/lvnode.env (see install.sh).
Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln(lvnodeVersion);
    return;
  }
  final AgentConfig config;
  try {
    config = AgentConfig.fromEnv(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('lvnode: ${e.message} (set it in /etc/lvnode.env)');
    exitCode = 2;
    return;
  }
  final agent = NodeAgent(config);
  await agent.start();
  if (Platform.isLinux) {
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signal.watch().listen((_) {
        agent.stop();
        exit(0);
      });
    }
  }
}
