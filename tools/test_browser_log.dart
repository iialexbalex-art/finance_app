import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Diagnostic only: connect to a disposable Flutter TEST tab, never an app tab.
Future<void> main(List<String> args) async {
  final socket = await WebSocket.connect(args.single);
  final subscription = socket.listen((data) {
    final row = jsonDecode(data as String) as Map<String, dynamic>;
    if (row['method'] == 'Log.entryAdded' ||
        row['method'] == 'Runtime.exceptionThrown') {
      stdout.writeln(data);
    }
  });
  socket.add(jsonEncode({'id': 1, 'method': 'Log.enable'}));
  socket.add(jsonEncode({'id': 2, 'method': 'Runtime.enable'}));
  await Future<void>.delayed(const Duration(seconds: 3));
  await subscription.cancel();
  await socket.close();
}
