// Development screenshot runner. Uses only fresh disposable local tabs.
// Launch headless Chrome with build/qa profile and debug port 9227 first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final http = HttpClient();
  try {
    final views = args.contains('--application')
        ? ['application']
        : ['collapsed', 'expanded', 'parent', 'mobile'];
    for (final name in views) {
      final response = await (await http.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:9227/json/new?about:blank'),
      )).close();
      final page = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, dynamic>;
      if (page['url'] != 'about:blank') {
        throw StateError('Only a fresh disposable page is allowed.');
      }
      final socket = await WebSocket.connect(
        page['webSocketDebuggerUrl'] as String,
      );
      var sequence = 0;
      final pending = <int, Completer<Map<String, dynamic>>>{};
      final exceptions = <String>[];
      final subscription = socket.listen((event) {
        final result = jsonDecode(event as String) as Map<String, dynamic>;
        final id = result['id'];
        if (id is int) {
          pending.remove(id)?.complete(result);
        } else if (result['method'] == 'Runtime.exceptionThrown') {
          exceptions.add(jsonEncode(result['params']));
        }
      });
      Future<Map<String, dynamic>> command(
        String method, [
        Map<String, dynamic>? params,
      ]) async {
        final id = ++sequence;
        final completion = Completer<Map<String, dynamic>>();
        pending[id] = completion;
        socket.add(
          jsonEncode({'id': id, 'method': method, 'params': params ?? {}}),
        );
        final result = await completion.future.timeout(
          const Duration(seconds: 20),
        );
        if (result['error'] != null) {
          throw StateError(jsonEncode(result['error']));
        }
        return result['result'] as Map<String, dynamic>;
      }

      try {
        await command('Page.enable');
        await command('Runtime.enable');
        final width = name == 'mobile' ? 320 : 1440;
        // Emulate before Flutter loads; never resize a running Flutter engine.
        await command('Emulation.setDeviceMetricsOverride', {
          'width': width,
          'height': 900,
          'deviceScaleFactor': 1,
          // Use a narrow browser viewport without changing the browser's
          // desktop platform identity (Flutter layout depends on width).
          'mobile': false,
          'screenWidth': width,
          'screenHeight': 900,
        });
        final view = name == 'mobile' ? 'expanded' : name;
        await command('Page.navigate', {
          'url': name == 'application'
              ? 'http://localhost:8080/'
              : 'http://localhost:8081/?view=$view',
        });
        // Real time allows PNG decoding and animation frames to finish.
        await Future<void>.delayed(const Duration(seconds: 8));
        final result = await command('Page.captureScreenshot', {
          'format': 'png',
          'captureBeyondViewport': false,
        });
        await Directory('build/qa/category-tree').create(recursive: true);
        await File('build/qa/category-tree/$name.png')
            .writeAsBytes(base64Decode(result['data'] as String));
        if (exceptions.isNotEmpty) {
          throw StateError(exceptions.join('\n'));
        }
        stdout.writeln(
          'Captured $name ($width x 900), no uncaught browser exceptions.',
        );
      } finally {
        await subscription.cancel();
        await socket.close();
        final closeResponse = await (await http.getUrl(
          Uri.parse('http://127.0.0.1:9227/json/close/${page['id']}'),
        )).close();
        await closeResponse.drain<void>();
      }
    }
  } finally {
    http.close();
  }
}
